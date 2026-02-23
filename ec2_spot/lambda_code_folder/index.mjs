import { EC2Client, RunInstancesCommand, DescribeInstancesCommand } from "@aws-sdk/client-ec2";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { createAppAuth } from "@octokit/auth-app"; 
import { Octokit } from "@octokit/core";           

const ec2Client = new EC2Client();
const secretsClient = new SecretsManagerClient();

// --- 1. THE USERDATA GENERATOR ---
const getUserDataScript = (repoUrl, token, runId, extraLabels) => {
    const labelList = extraLabels ? `${extraLabels},run-${runId}` : `run-${runId}`;
    return `#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -x

# 1. SETUP ENVIRONMENT
RUNNER_DIR="/home/ubuntu/actions-runner"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 2. INSTALL TOOLS (Standard requirements)
apt-get update -y
apt-get install -y unzip curl libicu-dev git build-essential nodejs

# 3. SETUP RUNNER
mkdir -p $RUNNER_DIR && cd $RUNNER_DIR
latest_version=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\\1/')
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/download/v$latest_version/actions-runner-linux-x64-$latest_version.tar.gz
tar xzf ./runner.tar.gz

# 4. FORCE ENVIRONMENT FILES
# This ensures the runner shell has a clean, functional PATH
cat <<EOT > .path
/usr/local/bin
/usr/bin
/bin
/usr/sbin
/sbin
EOT

cat <<EOT > .env
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOT

chown -R ubuntu:ubuntu $RUNNER_DIR

# 5. REGISTER AND START
sudo -u ubuntu -E ./config.sh --url "${repoUrl}" --token "${token}" --labels "${labelList}" --unattended --replace
sudo -u ubuntu -E ./run.sh &

# 6. WATCHDOG (Auto-shutdown when idle)
timeout 300s bash -c 'until pgrep -x "Runner.Worker" > /dev/null; do sleep 5; done'
IDLE_LIMIT=120
IDLE_COUNT=0
while [ $IDLE_COUNT -lt $IDLE_LIMIT ]; do
  if pgrep -x "Runner.Worker" > /dev/null; then
    IDLE_COUNT=0
  else
    IDLE_COUNT=$((IDLE_COUNT + 10))
  fi
  sleep 10
done
shutdown -h now
`;
};


export const handler = async (event, context) => {
    // This prevents Lambda from hanging if the SDK keeps connections open
    context.callbackWaitsForEmptyEventLoop = false;

    let body;
    try {
        // Handle both SQS (Records) and Direct/API Gateway (body) inputs
        body = event.Records ? JSON.parse(event.Records[0].body) : (typeof event.body === 'string' ? JSON.parse(event.body) : event.body);
    } catch (e) {
        console.error("JSON Parse Error:", e);
        return { statusCode: 400, body: "Invalid JSON body" };
    }
    
    // Standardize IDs
    const jobId = body.workflow_job?.id?.toString();
    const runId = (body.workflow_job?.run_id || body.workflow_run_id)?.toString();
    const repoUrl = body.repository?.html_url;
    const owner = body.repository?.owner?.login;
    const repo = body.repository?.name;

    if (body.action !== 'queued') return { statusCode: 200, body: "Ignore: Action not queued" };

    const jobLabels = body.workflow_job?.labels || [];
    const isSelfHosted = jobLabels.map(l => (typeof l === 'string' ? l : l.name).toLowerCase()).includes('self-hosted');

    if (!isSelfHosted) return { statusCode: 200, body: "Ignore: Not a self-hosted job" };

    try {
        // 1. CONCURRENCY CHECK (Check if we already started one)
        const describeCmd = new DescribeInstancesCommand({
            Filters: [
                { Name: 'tag:GH_Job_ID', Values: [jobId] },
                { Name: 'instance-state-name', Values: ['pending', 'running'] }
            ]
        });
        const existing = await ec2Client.send(describeCmd);
        if (existing.Reservations?.length > 0) {
            console.log(`Job ${jobId} already has a runner. Skipping.`);
            return { statusCode: 200, body: 'Job already has a runner' };
        }

        // 2. GITHUB AUTH & TOKEN
        const secretResponse = await secretsClient.send(new GetSecretValueCommand({ SecretId: process.env.SECRET_NAME }));
        const secrets = JSON.parse(secretResponse.SecretString);
        const octokit = new Octokit({
            authStrategy: createAppAuth,
            auth: { appId: secrets.GH_APP_ID, privateKey: secrets.GH_PRIVATE_KEY, installationId: secrets.GH_INSTALL_ID },
        });

        const { data } = await octokit.request('POST /repos/{owner}/{repo}/actions/runners/registration-token', { owner, repo });

        // 3. PREPARE PARAMS
        const typeList = (process.env.INSTANCE_TYPES || "t3.micro").split(',');
        const subnets = (process.env.SUBNET_IDS || "").split(',');
        const randomSubnet = subnets[Math.floor(Math.random() * subnets.length)];
        const userData = Buffer.from(getUserDataScript(repoUrl, data.token, runId, process.env.GH_LABELS)).toString('base64');

        const baseParams = {
            LaunchTemplate: { LaunchTemplateName: process.env.LT_NAME },
            MinCount: 1, MaxCount: 1,
            // IDEMPOTENCY TOKEN: AWS will ignore duplicate requests with this same ID
            ClientToken: `job-${jobId}`, 
            InstanceInitiatedShutdownBehavior: 'terminate',
            SubnetId: randomSubnet, 
            SecurityGroupIds: [process.env.SG_ID],  
            UserData: userData,
            TagSpecifications: [{
                ResourceType: "instance",
                Tags: [
                    { Key: "Name", Value: `Runner-Job-${jobId}` },
                    { Key: "GH_Job_ID", Value: jobId },
                    { Key: "Team", Value: "ap13" }, // Important for your IAM Policy
                    { Key: "ManagedBy", Value: "GitHub-Runner-Manager" }
                ]
            }]
        };

        // 4. ATTEMPT SPOT LAUNCH (Looping through types)
        for (const currentType of typeList) {
            try {
                await ec2Client.send(new RunInstancesCommand({
                    ...baseParams,
                    InstanceType: currentType,
                    InstanceMarketOptions: { MarketType: 'spot' }
                }));
                console.log(`SPOT SUCCESS: Launched ${currentType} for job ${jobId}`);
                return { statusCode: 200, body: `Launched Spot for Job ${jobId}` }; 
            } catch (error) {
                if (error.name === 'InsufficientInstanceCapacity' || error.name === 'InsufficientCapacity') {
                    console.log(`SPOT WARN: No capacity for ${currentType}, trying next...`);
                    continue;
                }
                throw error; 
            }
        }

        // 5. ON-DEMAND FALLBACK (Only runs if the loop above didn't return)
        console.log("SPOT FAIL: Attempting On-Demand fallback...");
        await ec2Client.send(new RunInstancesCommand({ 
            ...baseParams, 
            InstanceType: typeList[0] 
        }));
        
        return { statusCode: 200, body: "Launched On-Demand" };

    } catch (err) {
        console.error("CRITICAL FAILURE:", err.message);
        return { statusCode: 500, body: err.message };
    }
};