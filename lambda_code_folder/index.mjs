import { EC2Client, RunInstancesCommand, DescribeInstancesCommand } from "@aws-sdk/client-ec2";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "@octokit/core";

const ec2Client = new EC2Client();
const secretsClient = new SecretsManagerClient();

// --- CONSTANTS ---
const LAMBDA_TIMEOUT_BUFFER_MS = 10000;
const WATCHDOG_STARTUP_TIMEOUT = 600;
const WATCHDOG_IDLE_LIMIT = 120;
const SPOT_RETRY_ERRORS = [
    'InsufficientInstanceCapacity',
    'InsufficientCapacity',
    'SpotMaxPriceTooLow',
    'MaxSpotInstanceCountExceeded',
];

// --- STRUCTURED LOGGER ---
// Initialized with empty context, populated once jobId/runId are known
let logContext = {};
const log = (level, message, data = {}) => {
    console.log(JSON.stringify({
        level,
        message,
        timestamp: new Date().toISOString(),
        ...logContext,
        ...data,
    }));
};

// --- USERDATA GENERATOR ---
const getUserDataScript = (repoUrl, token, runId, extraLabels) => {
    const labelList = extraLabels ? `${extraLabels},run-${runId}` : `run-${runId}`;
    return `#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -x

# 1. SETUP ENVIRONMENT
RUNNER_DIR="/home/ubuntu/actions-runner"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 2. INSTALL TOOLS — with retry on transient network failures
for i in 1 2 3; do
  apt-get update -y && break
  echo "apt-get update failed, retry $i"
  sleep 10
done
apt-get install -y unzip curl libicu-dev git build-essential nodejs

# 3. SETUP RUNNER
mkdir -p $RUNNER_DIR && cd $RUNNER_DIR
latest_version=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\\1/')
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/download/v$latest_version/actions-runner-linux-x64-$latest_version.tar.gz
tar xzf ./runner.tar.gz

# 4. FORCE ENVIRONMENT FILES
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

# 6. WATCHDOG — wait for runner to start, then shutdown when idle
timeout ${WATCHDOG_STARTUP_TIMEOUT}s bash -c 'until pgrep -x "Runner.Worker" > /dev/null; do sleep 5; done'
IDLE_LIMIT=${WATCHDOG_IDLE_LIMIT}
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

// --- PARSE EVENT BODY ---
// Handles SQS (Records), API Gateway (string body), and direct invocation (object)
const parseEventBody = (event) => {
    const rawBody = event.Records ? event.Records[0].body : event.body ?? event;
    return typeof rawBody === 'string' ? JSON.parse(rawBody) : rawBody;
};

// --- VALIDATE REQUIRED FIELDS ---
const validateFields = ({ jobId, runId, repoUrl, owner, repo }) => {
    const missing = [];
    if (!jobId)   missing.push('jobId');
    if (!runId)   missing.push('runId');
    if (!repoUrl) missing.push('repoUrl');
    if (!owner)   missing.push('owner');
    if (!repo)    missing.push('repo');
    return missing;
};

// --- CHECK FOR EXISTING RUNNER ---
const hasExistingRunner = async (jobId) => {
    const response = await ec2Client.send(new DescribeInstancesCommand({
        Filters: [
            { Name: 'tag:GH_Job_ID', Values: [jobId] },
            { Name: 'instance-state-name', Values: ['pending', 'running'] },
        ],
    }));
    return (response.Reservations?.length ?? 0) > 0;
};

// --- FETCH GITHUB REGISTRATION TOKEN ---
const getRegistrationToken = async (owner, repo) => {
    const secretResponse = await secretsClient.send(
        new GetSecretValueCommand({ SecretId: process.env.SECRET_NAME })
    );
    const secrets = JSON.parse(secretResponse.SecretString);

    const octokit = new Octokit({
        authStrategy: createAppAuth,
        auth: {
            appId:          secrets.GH_APP_ID,
            privateKey:     secrets.GH_PRIVATE_KEY,
            installationId: secrets.GH_INSTALL_ID,
        },
    });

    const { data } = await octokit.request(
        'POST /repos/{owner}/{repo}/actions/runners/registration-token',
        { owner, repo }
    );

    if (!data.token) {
        throw new Error("GitHub API returned empty registration token");
    }

    return data.token;
};

// --- BUILD EC2 LAUNCH PARAMS ---
const buildLaunchParams = ({ jobId, runId, repoUrl, token, selectedSubnet }) => {
    // Token is embedded in UserData — never log it separately
    const userData = Buffer.from(
        getUserDataScript(repoUrl, token, runId, process.env.GH_LABELS)
    ).toString('base64');

    return {
        LaunchTemplate: { LaunchTemplateName: process.env.LT_NAME },
        MinCount: 1,
        MaxCount: 1,
        ClientToken: `job-${jobId}`,               // Idempotency — AWS ignores duplicate requests
        InstanceInitiatedShutdownBehavior: 'terminate',
        SubnetId: selectedSubnet,
        SecurityGroupIds: [process.env.SG_ID],
        UserData: userData,
        TagSpecifications: [{
            ResourceType: "instance",
            Tags: [
                { Key: "Name",       Value: `Runner-Job-${jobId}` },
                { Key: "GH_Job_ID",  Value: jobId },
                { Key: "Team",       Value: "ap13" },
                { Key: "ManagedBy",  Value: "GitHub-Runner-Manager" },
            ],
        }],
    };
};

// --- LAUNCH SPOT WITH ON-DEMAND FALLBACK ---
const launchInstance = async (baseParams, typeList) => {
    // Attempt spot launch across all instance types
    for (const instanceType of typeList) {
        try {
            await ec2Client.send(new RunInstancesCommand({
                ...baseParams,
                InstanceType: instanceType,
                InstanceMarketOptions: { MarketType: 'spot' },
            }));
            log('INFO', `Spot instance launched`, { instanceType });
            return { type: 'spot', instanceType };
        } catch (error) {
            if (SPOT_RETRY_ERRORS.includes(error.name)) {
                log('WARN', `Spot capacity unavailable, trying next type`, { instanceType, error: error.name });
                continue;
            }
            throw error; // Unexpected error — rethrow immediately
        }
    }

    // All spot attempts failed — fall back to on-demand
    log('WARN', 'All spot attempts failed, falling back to on-demand');
    const onDemandType = process.env.ON_DEMAND_INSTANCE_TYPE || typeList[0];
    await ec2Client.send(new RunInstancesCommand({
        ...baseParams,
        InstanceType: onDemandType,
        // No InstanceMarketOptions = on-demand
    }));
    log('INFO', `On-demand instance launched`, { instanceType: onDemandType });
    return { type: 'on-demand', instanceType: onDemandType };
};

// --- MAIN HANDLER ---
export const handler = async (event, context) => {
    // Prevents Lambda from hanging if SDK keeps connections open
    context.callbackWaitsForEmptyEventLoop = false;

    // Guard against Lambda timeout mid-execution
    if (context.getRemainingTimeInMillis() < LAMBDA_TIMEOUT_BUFFER_MS) {
        log('ERROR', 'Lambda timeout imminent, aborting before execution');
        return { statusCode: 500, body: 'Lambda timeout' };
    }

    // Log SQS message ID for DLQ tracing
    const messageId = event.Records?.[0]?.messageId;
    if (messageId) log('INFO', 'Processing SQS message', { messageId });

    // --- PARSE BODY ---
    let body;
    try {
        body = parseEventBody(event);
    } catch (e) {
        log('ERROR', 'Failed to parse event body', { error: e.message });
        return { statusCode: 400, body: 'Invalid JSON body' };
    }

    // --- EXTRACT FIELDS ---
    const jobId  = body.workflow_job?.id?.toString();
    const runId  = body.workflow_job?.run_id?.toString();   // Fixed: removed unreliable fallback
    const repoUrl = body.repository?.html_url;
    const owner  = body.repository?.owner?.login;
    const repo   = body.repository?.name;

    // Set log context once fields are known
    logContext = { jobId, runId, owner, repo };

    // --- VALIDATE FIELDS ---
    const missingFields = validateFields({ jobId, runId, repoUrl, owner, repo });
    if (missingFields.length > 0) {
        log('ERROR', 'Missing required webhook fields', { missingFields });
        return { statusCode: 400, body: `Missing fields: ${missingFields.join(', ')}` };
    }

    // --- FILTER: only handle queued self-hosted jobs ---
    if (body.action !== 'queued') {
        log('INFO', 'Ignoring non-queued action', { action: body.action });
        return { statusCode: 200, body: 'Ignore: Action not queued' };
    }

    const jobLabels = body.workflow_job?.labels || [];
    const isSelfHosted = jobLabels
        .map(l => (typeof l === 'string' ? l : l.name).toLowerCase())
        .includes('self-hosted');

    if (!isSelfHosted) {
        log('INFO', 'Ignoring non-self-hosted job', { labels: jobLabels });
        return { statusCode: 200, body: 'Ignore: Not a self-hosted job' };
    }

    try {
        // --- CONCURRENCY CHECK ---
        if (await hasExistingRunner(jobId)) {
            log('INFO', 'Runner already exists for this job, skipping');
            return { statusCode: 200, body: 'Job already has a runner' };
        }

        // --- GITHUB TOKEN ---
        const token = await getRegistrationToken(owner, repo);
        log('INFO', 'GitHub registration token obtained'); // Never log the token value

        // --- SUBNET SELECTION ---
        // Deterministic selection based on jobId — same job always goes to same subnet
        const subnets = (process.env.SUBNET_IDS || '').split(',').filter(Boolean);
        if (subnets.length === 0) throw new Error('SUBNET_IDS environment variable is not set');
        const selectedSubnet = subnets[parseInt(jobId) % subnets.length];

        // --- BUILD PARAMS ---
        const typeList = (process.env.INSTANCE_TYPES || 't3.micro').split(',').filter(Boolean);
        const baseParams = buildLaunchParams({ jobId, runId, repoUrl, token, selectedSubnet });

        // --- LAUNCH ---
        const result = await launchInstance(baseParams, typeList);

        log('INFO', 'Runner launched successfully', {
            launchType:   result.type,
            instanceType: result.instanceType,
            subnet:       selectedSubnet,
        });

        return {
            statusCode: 200,
            body: JSON.stringify({
                message:      `Runner launched for job ${jobId}`,
                launchType:   result.type,
                instanceType: result.instanceType,
            }),
        };

    } catch (err) {
        log('ERROR', 'Critical failure launching runner', { error: err.message, stack: err.stack });
        return { statusCode: 500, body: err.message };
    }
};
