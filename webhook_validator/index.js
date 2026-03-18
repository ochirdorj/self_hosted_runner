'use strict';

const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const crypto = require('crypto');

const smClient  = new SecretsManagerClient({});
const sqsClient = new SQSClient({});

// Cache the secret across warm Lambda invocations
let cachedWebhookSecret = null;

async function getWebhookSecret() {
  if (cachedWebhookSecret) return cachedWebhookSecret;

  const res = await smClient.send(new GetSecretValueCommand({
    SecretId: process.env.SECRET_NAME,
  }));

  const parsed = JSON.parse(res.SecretString);
  const key = process.env.WEBHOOK_SECRET_KEY ?? 'webhook_secret';

  if (!parsed[key]) {
    throw new Error(`Key "${key}" not found in secret "${process.env.SECRET_NAME}"`);
  }

  cachedWebhookSecret = parsed[key];
  return cachedWebhookSecret;
}

/**
 * Constant-time HMAC comparison to prevent timing attacks.
 * Returns true only if the signature matches.
 */
function verifySignature(secret, rawBody, sigHeader) {
  const expected = 'sha256=' + crypto
    .createHmac('sha256', secret)
    .update(rawBody, 'utf8')
    .digest('hex');

  try {
    // Buffers must be the same length for timingSafeEqual
    const a = Buffer.from(sigHeader);
    const b = Buffer.from(expected);
    if (a.length !== b.length) return false;
    return crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

exports.handler = async (event) => {
  // GitHub always lowercases headers in API Gateway payload format v1
  const sigHeader = event.headers?.['x-hub-signature-256'];

  if (!sigHeader) {
    console.warn('Rejected: missing X-Hub-Signature-256 header');
    return {
      statusCode: 401,
      body: JSON.stringify({ message: 'Missing X-Hub-Signature-256' }),
    };
  }

  const rawBody = event.body ?? '';

  let secret;
  try {
    secret = await getWebhookSecret();
  } catch (err) {
    console.error('Failed to retrieve webhook secret:', err);
    return {
      statusCode: 500,
      body: JSON.stringify({ message: 'Internal error' }),
    };
  }

  if (!verifySignature(secret, rawBody, sigHeader)) {
    console.warn('Rejected: signature mismatch');
    return {
      statusCode: 401,
      body: JSON.stringify({ message: 'Invalid signature' }),
    };
  }

  // Signature is valid — forward to SQS
  try {
    await sqsClient.send(new SendMessageCommand({
      QueueUrl: process.env.SQS_QUEUE_URL,
      MessageBody: rawBody,
    }));
  } catch (err) {
    console.error('Failed to enqueue message:', err);
    return {
      statusCode: 500,
      body: JSON.stringify({ message: 'Failed to enqueue webhook' }),
    };
  }

  return {
    statusCode: 200,
    body: JSON.stringify({ status: 'accepted' }),
  };
};
