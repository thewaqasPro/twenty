#!/usr/bin/env node
/**
 * Provision Workspace Engine for Twenty CRM on Dokploy
 * 
 * Automates:
 * 1. Twenty workspace registration (signUpInNewWorkspace)
 * 2. Database schema initialization & seeding (activateWorkspace)
 * 3. Exact subdomain configuration (core.workspace.subdomain)
 * 4. Dokploy domain registration and Traefik SSL deployment
 */

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const { execSync } = require('child_process');

function parseEnvFile(filePath) {
  const env = {};
  if (!fs.existsSync(filePath)) return env;
  const content = fs.readFileSync(filePath, 'utf8');
  for (const rawLine of content.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    const idx = line.indexOf('=');
    const key = line.slice(0, idx).trim();
    let val = line.slice(idx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    env[key] = val;
  }
  return env;
}

const rootDir = path.resolve(__dirname, '..');
const prodEnv = parseEnvFile(path.join(rootDir, '.env.production'));
const dokployEnv = parseEnvFile(path.join(rootDir, '.env.dokploy'));

const ENCRYPTION_KEY = prodEnv.ENCRYPTION_KEY;
const VPS_IP = dokployEnv.DOKPLOY_VPS_IP || '2.25.71.201';
const DOKPLOY_URL = dokployEnv.DOKPLOY_URL || 'https://console.kyndstudio.com';
const DOKPLOY_API_KEY = dokployEnv.DOKPLOY_API_KEY;
const COMPOSE_ID = dokployEnv.DOKPLOY_COMPOSE_ID || 'C2yGJCMsac398s_cfwmEb';
const BASE_DOMAIN = 'crm.kyndstudio.com';
const MAX_WORKSPACES = parseInt(prodEnv.MAX_WORKSPACES_WITHOUT_ENTERPRISE_KEY || '100', 10);

let pgUrl = prodEnv.PG_DATABASE_URL || '';
if (pgUrl.includes('@database-postgresql-adg7lr:')) {
  pgUrl = pgUrl.replace('@database-postgresql-adg7lr:', `@${VPS_IP}:`);
}

function psql(sql) {
  if (!pgUrl) throw new Error('PG_DATABASE_URL not found in .env.production');
  const sanitized = sql.replace(/"/g, '\\"');
  return execSync(`psql "${pgUrl}" -t -A -c "${sanitized}"`, { encoding: 'utf8' }).trim();
}

function dokployRequest(endpoint, method = 'GET', body = null) {
  return new Promise((resolve, reject) => {
    const postData = body ? JSON.stringify(body) : '';
    const url = new URL(endpoint, DOKPLOY_URL);
    const req = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname + url.search,
      method: method,
      headers: {
        'x-api-key': DOKPLOY_API_KEY,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
      },
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          resolve({ status: res.statusCode, body: parsed });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    if (postData) req.write(postData);
    req.end();
  });
}

function getPrivateKeyPem() {
  const keyRow = psql('SELECT id || \':::\' || "privateKey" FROM core."signingKey" WHERE "isCurrent" = true LIMIT 1;');
  if (!keyRow) throw new Error('No current signingKey found in core."signingKey"');
  const [keyId, encVal] = keyRow.split(':::');

  const parts = encVal.split(':');
  if (parts.length < 4) throw new Error('Invalid signingKey cipher format');
  const payloadBuf = Buffer.from(parts[3], 'base64');
  const iv = payloadBuf.subarray(0, 12);
  const authTag = payloadBuf.subarray(payloadBuf.length - 16);
  const ciphertext = payloadBuf.subarray(12, payloadBuf.length - 16);

  const derivedKey = crypto.hkdfSync(
    'sha256',
    Buffer.from(ENCRYPTION_KEY),
    Buffer.alloc(32),
    Buffer.from('twenty:enc:v2:instance'),
    32,
  );

  const decipher = crypto.createDecipheriv('aes-256-gcm', derivedKey, iv);
  decipher.setAuthTag(authTag);
  const privateKeyPem = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');

  return { keyId, privateKeyPem };
}

function signJwt(payload, keyId, privateKeyPem) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'ES256', typ: 'JWT', kid: keyId };
  const fullPayload = { ...payload, iat: now, exp: now + 3600 };

  const b64url = obj => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const signInput = `${b64url(header)}.${b64url(fullPayload)}`;
  const sign = crypto.createSign('SHA256');
  sign.update(signInput);
  sign.end();
  const signature = sign.sign({ key: privateKeyPem, dsaEncoding: 'ieee-p1363' }, 'base64url');
  return `${signInput}.${signature}`;
}

function graphqlRequest(endpoint, query, variables, token) {
  return new Promise((resolve, reject) => {
    const url = new URL(endpoint);
    const postData = JSON.stringify({ query, variables });
    const req = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
        ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
      },
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (parsed.errors && parsed.errors.length > 0) {
            reject(new Error(parsed.errors[0].message || JSON.stringify(parsed.errors)));
          } else {
            resolve(parsed.data);
          }
        } catch {
          reject(new Error(`Failed to parse GraphQL response: ${data}`));
        }
      });
    });
    req.on('error', reject);
    req.write(postData);
    req.end();
  });
}

function listWorkspaces() {
  const countRaw = psql('SELECT COUNT(*) FROM core.workspace WHERE "activationStatus" = \'ACTIVE\';');
  const count = parseInt(countRaw, 10) || 0;
  console.log(`\n======================================================`);
  console.log(` Active Twenty Workspaces (${count}/${MAX_WORKSPACES} slots used)`);
  console.log(`======================================================`);
  
  const rows = psql('SELECT id || \' | \' || "displayName" || \' | \' || subdomain || \' | \' || COALESCE("customDomain", \'\') || \' | \' || "isCustomDomainEnabled" || \' | \' || "activationStatus" FROM core.workspace ORDER BY "createdAt" ASC;');
  if (!rows) {
    console.log('No workspaces found.');
    return;
  }
  for (const row of rows.split('\n')) {
    const [id, name, sub, customDomain, isCustomEnabled, status] = row.split(' | ');
    const isPrimary = isCustomEnabled === 'true' && customDomain;
    const url = isPrimary ? `https://${customDomain}` : `https://${sub}.${BASE_DOMAIN}`;
    const tag = isPrimary ? '[PRIMARY AGENCY]' : '[CLIENT]';
    console.log(` • ${tag.padEnd(16)} [${status}] ${name.padEnd(20)} => ${url} (ID: ${id})`);
  }
  console.log('======================================================\n');
}

async function provisionWorkspace(name, subdomain) {
  console.log(`\n--- Starting Provisioning for "${name}" (${subdomain}.${BASE_DOMAIN}) ---`);

  // 1. Validate inputs
  const subClean = subdomain.trim().toLowerCase();
  if (!/^[a-z0-9-]+$/.test(subClean)) {
    throw new Error(`Invalid subdomain: "${subClean}". Must contain only lowercase alphanumeric characters and hyphens.`);
  }

  const reserved = ['app', 'crm', 'admin', 'api', 'n8n', 'console', 'postgres', 'redis', 'agency'];
  if (reserved.includes(subClean)) {
    throw new Error(`Subdomain "${subClean}" is reserved and cannot be assigned to a client.`);
  }

  // 2. Check limits & existing workspaces
  const existingSub = psql(`SELECT id FROM core.workspace WHERE subdomain = '${subClean}' LIMIT 1;`);
  if (existingSub) {
    throw new Error(`Subdomain "${subClean}" is already in use by workspace ${existingSub}.`);
  }

  const activeCountRaw = psql('SELECT COUNT(*) FROM core.workspace WHERE "activationStatus" = \'ACTIVE\';');
  const activeCount = parseInt(activeCountRaw, 10) || 0;
  if (activeCount >= MAX_WORKSPACES) {
    throw new Error(`Workspace limit reached: ${activeCount}/${MAX_WORKSPACES} active workspaces. Upgrade or remove unused workspaces.`);
  }

  // 3. Resolve Admin User & Signing Key
  const adminRow = psql('SELECT id || \':::\' || email FROM core."user" WHERE "canAccessFullAdminPanel" = true LIMIT 1;');
  if (!adminRow) throw new Error('No server admin found in core."user"');
  const [adminId, adminEmail] = adminRow.split(':::');
  console.log(`[1/5] Server Admin identified: ${adminEmail}`);

  const { keyId, privateKeyPem } = getPrivateKeyPem();
  console.log(`[2/5] Decrypted active ES256 signing key (kid: ${keyId})`);

  // 4. Create Workspace (signUpInNewWorkspace)
  console.log(`[3/5] Requesting new workspace creation via Twenty Metadata API...`);
  const agnosticJwt = signJwt({
    sub: adminId,
    userId: adminId,
    type: 'WORKSPACE_AGNOSTIC',
    authProvider: 'password',
  }, keyId, privateKeyPem);

  const signUpRes = await graphqlRequest(
    `https://${BASE_DOMAIN}/metadata`,
    `mutation SignUpInNewWorkspace {
      signUpInNewWorkspace {
        workspace {
          id
        }
      }
    }`,
    {},
    agnosticJwt,
  );

  const workspaceId = signUpRes.signUpInNewWorkspace.workspace.id;
  console.log(`      Created pending workspace: ${workspaceId}`);

  // 5. Activate Workspace (Creates Postgres schema, default objects, member)
  console.log(`[4/5] Activating workspace and initializing schema...`);
  const uwRow = psql(`SELECT id FROM core."userWorkspace" WHERE "workspaceId" = '${workspaceId}' LIMIT 1;`);
  const userWorkspaceId = uwRow.trim();

  const accessJwt = signJwt({
    sub: adminId,
    userId: adminId,
    workspaceId: workspaceId,
    userWorkspaceId: userWorkspaceId,
    authProvider: 'password',
    type: 'ACCESS',
    isImpersonating: false,
  }, keyId, privateKeyPem);

  const activateRes = await graphqlRequest(
    `https://${BASE_DOMAIN}/metadata`,
    `mutation ActivateWorkspace($data: ActivateWorkspaceInput!) {
      activateWorkspace(data: $data) {
        id
        displayName
        activationStatus
      }
    }`,
    { data: { displayName: name } },
    accessJwt,
  );

  console.log(`      Workspace activated with status: ${activateRes.activateWorkspace.activationStatus}`);

  // 6. Set custom subdomain and clean canonical flags
  psql(`UPDATE core.workspace SET subdomain = '${subClean}', "customDomain" = NULL, "isCustomDomainEnabled" = false WHERE id = '${workspaceId}';`);
  console.log(`      Assigned subdomain: ${subClean}.${BASE_DOMAIN}`);

  // 7. Register domain in Dokploy and redeploy Traefik
  console.log(`[5/5] Registering domain in Dokploy and triggering Traefik router deployment...`);
  const host = `${subClean}.${BASE_DOMAIN}`;

  // Check if domain already registered in Dokploy
  const domainsRes = await dokployRequest(`/api/domain.byComposeId?composeId=${COMPOSE_ID}`);
  const existingDomain = Array.isArray(domainsRes.body) ? domainsRes.body.find(d => d.host === host) : null;

  if (!existingDomain) {
    const createRes = await dokployRequest('/api/domain.create', 'POST', {
      composeId: COMPOSE_ID,
      host: host,
      port: 3000,
      serviceName: 'server',
      domainType: 'compose',
      certificateType: 'letsencrypt',
      https: true,
    });
    if (createRes.status !== 200 && createRes.status !== 201) {
      console.warn(`      Dokploy domain.create warning: ${JSON.stringify(createRes.body)}`);
    } else {
      console.log(`      Registered domain in Dokploy: ${host}`);
    }
  } else {
    console.log(`      Domain ${host} is already registered in Dokploy.`);
  }

  // Trigger compose deploy so Dokploy generates Traefik labels & Let's Encrypt certificate
  const deployRes = await dokployRequest('/api/compose.deploy', 'POST', { composeId: COMPOSE_ID });
  console.log(`      Triggered Dokploy deployment: ${deployRes.body.message || 'Queued'}`);

  console.log(`\n======================================================`);
  console.log(`  WORKSPACE PROVISIONED SUCCESSFULLY!`);
  console.log(`======================================================`);
  console.log(`  Workspace Name : ${name}`);
  console.log(`  Subdomain URL  : https://${host}`);
  console.log(`  Workspace ID   : ${workspaceId}`);
  console.log(`  Admin Account  : ${adminEmail}`);
  console.log(`  Status         : ACTIVE`);
  console.log(`======================================================\n`);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--list') || args.includes('-l')) {
    listWorkspaces();
    return;
  }

  let name = null;
  let subdomain = null;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--name' || args[i] === '-n') {
      name = args[++i];
    } else if (args[i] === '--subdomain' || args[i] === '-s') {
      subdomain = args[++i];
    }
  }

  if (!name || !subdomain) {
    console.log(`Usage:`);
    console.log(`  node scripts/provision-workspace.js --name "Acme Corp" --subdomain "acme"`);
    console.log(`  node scripts/provision-workspace.js --list`);
    process.exit(1);
  }

  await provisionWorkspace(name, subdomain);
}

main().catch(err => {
  console.error('\nPROVISIONING FAILED:', err.message || err);
  process.exit(1);
});
