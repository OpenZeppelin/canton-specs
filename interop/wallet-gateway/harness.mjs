#!/usr/bin/env node
// CIP-0103 third-party interop harness: drives the OpenZeppelin CIP-0112
// settlement surface through the Canton Wallet Gateway (the CIP-0103
// implementation formerly known as Splice Wallet Kernel).
//
// The wallet user is an externally-signed party created and held by the
// gateway (built-in `wallet-kernel` Ed25519 signing driver). Every wallet-side
// ledger action goes through the gateway's CIP-0103 dApp JSON-RPC API
// (`prepareExecute` + `txChanged` + `ledgerApi`); transaction approval uses the
// gateway's user JSON-RPC API (`sign` + `execute`), i.e. the same calls the
// gateway's own approve UI makes. No direct Ledger API access is used for the
// wallet party anywhere in this file.
//
// Subcommands (orchestrated by scripts/wallet-gateway-cip0103-interop.sh):
//   create-wallet      create session + externally-signed wallet party
//   dapp-flow          connect, accept offers/request, build the allocation
//   verify-wallet-view assert the wallet's post-settlement projection
//
// Experiment-only; no conformance or production claim.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const GATEWAY = process.env.OZ_GATEWAY_URL ?? 'http://127.0.0.1:3030'
const USER_API = `${GATEWAY}/api/v0/user`
const DAPP_API = `${GATEWAY}/api/v0/dapp`
const JSON_API = process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:7575'
const NETWORK_ID = process.env.OZ_GATEWAY_NETWORK_ID ?? 'canton:local-sandbox'
const WORK_DIR = process.env.OZ_INTEROP_WORK_DIR ?? '.cache/wallet-gateway-interop'
const LEDGER_USER = 'oz-cip0103-interop'
const EXTERNAL = process.env.OZ_USE_EXTERNAL_LEDGER === '1'

const PKG_INTEROP = '#openzeppelin-experimental-cip-interop-exemplar'
const PKG_SETTLEMENT = '#openzeppelin-experimental-cip112-settlement'
const MOD_GATEWAY = 'OpenZeppelin.Experimental.Interop.WalletGateway'
const MOD_ENGINE = 'OpenZeppelin.Experimental.Settlement.Cip112'
const T = {
  holdingOffer: `${PKG_INTEROP}:${MOD_GATEWAY}:GatewayHoldingOffer`,
  allocationOffer: `${PKG_INTEROP}:${MOD_GATEWAY}:GatewayAllocationOffer`,
  allocationRequest: `${PKG_SETTLEMENT}:${MOD_ENGINE}:AllocationRequest`,
  factory: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementFactory`,
  instruction: `${PKG_SETTLEMENT}:${MOD_ENGINE}:AllocationInstruction`,
  toyHolding: `${PKG_SETTLEMENT}:${MOD_ENGINE}:ToyHolding`,
  allocation: `${PKG_SETTLEMENT}:${MOD_ENGINE}:Allocation`,
  receipt: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementReceipt`,
  eventLog: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementEventLogEntry`,
}

let rpcId = 0
const log = (...args) => console.log('[harness]', ...args)

function fail(msg) {
  console.error('[harness] FAIL:', msg)
  process.exit(1)
}

async function rpc(url, method, params, token) {
  const headers = { 'content-type': 'application/json' }
  if (token) headers.authorization = `Bearer ${token}`
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ jsonrpc: '2.0', id: `oz-${++rpcId}`, method, params }),
  })
  const text = await res.text()
  let body
  try {
    body = JSON.parse(text)
  } catch {
    throw new Error(`${method}: non-JSON response (HTTP ${res.status}): ${text.slice(0, 500)}`)
  }
  if (body.error) {
    throw new Error(`${method}: JSON-RPC error ${body.error.code}: ${body.error.message} ${JSON.stringify(body.error.data ?? '')}`)
  }
  return body.result
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function poll(desc, timeoutMs, intervalMs, fn) {
  const deadline = Date.now() + timeoutMs
  let lastErr
  while (Date.now() < deadline) {
    try {
      const value = await fn()
      if (value !== undefined && value !== null && value !== false) return value
    } catch (err) {
      lastErr = err
    }
    await sleep(intervalMs)
  }
  throw new Error(`timeout waiting for ${desc}${lastErr ? `: last error: ${lastErr.message}` : ''}`)
}

function readJson(name) {
  return JSON.parse(readFileSync(join(WORK_DIR, name), 'utf8'))
}

function writeJson(name, value) {
  mkdirSync(WORK_DIR, { recursive: true })
  writeFileSync(join(WORK_DIR, name), JSON.stringify(value, null, 2))
  log(`wrote ${join(WORK_DIR, name)}`)
}

// --- gateway ledgerApi passthrough (the CIP-0103 read surface) --------------

async function ledgerApi(token, requestMethod, resource, body) {
  return rpc(DAPP_API, 'ledgerApi', { requestMethod, resource, ...(body ? { body } : {}) }, token)
}

// Query the wallet party's active contracts for one template via the gateway.
async function acs(token, party, templateId) {
  const end = await ledgerApi(token, 'get', '/v2/state/ledger-end')
  const offset = end?.offset ?? end?.body?.offset
  if (offset === undefined) throw new Error(`ledger-end gave no offset: ${JSON.stringify(end)}`)
  const request = {
    filter: {
      filtersByParty: {
        [party]: {
          cumulative: [
            {
              identifierFilter: {
                TemplateFilter: {
                  value: { templateId, includeCreatedEventBlob: false },
                },
              },
            },
          ],
        },
      },
    },
    verbose: false,
    activeAtOffset: offset,
  }
  const res = await ledgerApi(token, 'post', '/v2/state/active-contracts', request)
  const items = Array.isArray(res) ? res : Array.isArray(res?.body) ? res.body : null
  if (items === null) {
    throw new Error(`active-contracts: unrecognized response shape: ${JSON.stringify(res).slice(0, 400)}`)
  }
  const contracts = []
  for (const item of items) {
    const entry = item?.contractEntry?.JsActiveContract ?? item?.contractEntry?.activeContract
    const ev = entry?.createdEvent
    if (ev) contracts.push({ contractId: ev.contractId, payload: ev.createArgument ?? ev.createArguments })
  }
  // Fail loudly on schema drift: a non-empty response none of whose entries
  // parse means the pinned gateway/ledger schema changed, and returning []
  // would surface only as an opaque downstream poll timeout.
  if (items.length > 0 && contracts.length === 0) {
    throw new Error(`active-contracts: ${items.length} entries but none parseable; first: ${JSON.stringify(items[0]).slice(0, 400)}`)
  }
  return contracts
}

// --- dApp command submission + user-side approval ----------------------------

async function exerciseViaGateway(token, party, label, templateId, contractId, choice, choiceArgument) {
  const commandId = `oz-cip0103-interop-${label}`
  log(`prepareExecute ${choice} (commandId=${commandId})`)
  await rpc(
    DAPP_API,
    'prepareExecute',
    {
      commandId,
      commands: [{ ExerciseCommand: { templateId, contractId, choice, choiceArgument } }],
    },
    token
  )

  // The remote gateway parks the prepared transaction for user approval.
  // Approve it programmatically through the user API, exactly as the
  // gateway's own approve page does: sign, then execute.
  const tx = await poll(`pending transaction ${commandId}`, 30_000, 300, async () => {
    const { transactions } = await rpc(USER_API, 'listTransactions', {}, token)
    return transactions.find((t) => t.commandId === commandId && t.status === 'pending')
  })
  log(`sign transaction ${tx.id}`)
  const signed = await rpc(USER_API, 'sign', { transactionId: tx.id, partyId: party }, token)
  if (signed.status !== 'signed') {
    throw new Error(`sign returned status ${signed.status}: ${JSON.stringify(signed)}`)
  }
  log(`execute transaction ${tx.id}`)
  await rpc(
    USER_API,
    'execute',
    { signature: signed.signature, signedBy: signed.signedBy, transactionId: tx.id, partyId: party },
    token
  )
  const done = await poll(`transaction ${commandId} executed`, 30_000, 300, async () => {
    const transaction = await rpc(USER_API, 'getTransaction', { transactionId: tx.id }, token)
    if (transaction.status === 'failed') throw new Error(`transaction failed: ${JSON.stringify(transaction)}`)
    return transaction.status === 'executed' ? transaction : undefined
  })
  log(`executed ${choice} (transaction ${done.id})`)
  return done
}

// --- txChanged SSE listener (CIP-0103 event surface) -------------------------

function listenTxChanged(token) {
  const events = []
  const controller = new AbortController()
  const url = `${DAPP_API}/events?token=${encodeURIComponent(token)}`
  const done = (async () => {
    try {
      const res = await fetch(url, {
        headers: { accept: 'text/event-stream' },
        signal: controller.signal,
      })
      if (!res.ok || !res.body) throw new Error(`SSE connect failed: HTTP ${res.status}`)
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''
      for (;;) {
        const { value, done: eof } = await reader.read()
        if (eof) break
        buf += decoder.decode(value, { stream: true })
        let idx
        while ((idx = buf.indexOf('\n\n')) >= 0) {
          const frame = buf.slice(0, idx)
          buf = buf.slice(idx + 2)
          const eventLine = frame.split('\n').find((l) => l.startsWith('event:'))
          const dataLine = frame.split('\n').find((l) => l.startsWith('data:'))
          if (!dataLine) continue
          const eventName = eventLine ? eventLine.slice(6).trim() : 'message'
          try {
            events.push({ event: eventName, data: JSON.parse(dataLine.slice(5).trim()) })
          } catch {
            events.push({ event: eventName, data: dataLine.slice(5).trim() })
          }
        }
      }
    } catch (err) {
      if (err.name !== 'AbortError') log(`SSE listener ended: ${err.message}`)
    }
  })()
  return {
    events,
    stop: async () => {
      controller.abort()
      await done.catch(() => {})
    },
  }
}

// --- external mode: operator-side phases over the JSON Ledger API -----------
//
// On managed devnet/testnet validators (e.g. ChainSafe dev1) only the JSON
// Ledger API is exposed — there is no gRPC endpoint for `dpm script` to use.
// In external mode the operator-side phases (setup / settle / verify) are
// therefore driven directly against the JSON Ledger API as the operator
// party. These values MUST mirror the Daml module's deterministic constants
// (`gatewayRef`, `gatewaySettlement`, `gatewayLeg`, amounts, feature flag):
// the on-ledger accept choice rebuilds them independently and the settle
// batch compares them for equality.

const REF = 'cip0103-wallet-gateway-interop'
const META = { entries: [] }
const FEATURE_FLAG = 'experimental.cip112-settlement.enabled'
const MINT = '40.0'
const TRANSFER = '25.0'
const acct = (p) => ({ owner: p, provider: null, id: '' })
const settlementInfo = (op) => ({
  executors: [op],
  settlementRef: { id: REF, cidText: null },
  settlementDeadline: null,
  meta: META,
})
const transferLeg = (wallet, op) => ({
  transferLegId: `${REF}-leg`,
  sender: acct(wallet),
  receiver: acct(op),
  amount: TRANSFER,
  instrumentId: 'USD',
  meta: META,
})
const legSide = (side, leg) => ({
  transferLegId: leg.transferLegId,
  side,
  otherside: side === 'SenderSide' ? leg.receiver : leg.sender,
  amount: leg.amount,
  instrumentId: leg.instrumentId,
  meta: leg.meta,
})

async function jsonApiDirect(token, method, path, body) {
  const res = await fetch(`${JSON_API}${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}: ${text.slice(0, 500)}`)
  return text ? JSON.parse(text) : undefined
}

let extCmd = 0
async function submitAndWait(token, actAs, label, commands) {
  const commandId = `oz-cip0103-external-${label}-${++extCmd}`
  log(`submit ${label} (as ${actAs.slice(0, 24)}…)`)
  const res = await jsonApiDirect(token, 'POST', '/v2/commands/submit-and-wait-for-transaction', {
    commands: { commands, commandId, actAs: [actAs] },
  })
  const events = res?.transaction?.events ?? []
  const created = []
  for (const e of events) {
    const ev = e?.CreatedEvent ?? e?.created ?? e?.CreatedTreeEvent?.value
    if (ev) created.push({ contractId: ev.contractId, templateId: ev.templateId, payload: ev.createArgument ?? ev.createArguments })
  }
  return { created, updateId: res?.transaction?.updateId }
}

const createdOf = (result, entity) => {
  const hit = result.created.find((c) => c.templateId?.endsWith(`:${entity}`) || c.templateId?.includes(`:${entity}`))
  if (!hit) throw new Error(`no created ${entity} in transaction; created: ${result.created.map((c) => c.templateId).join(', ')}`)
  return hit.contractId
}

// Direct ACS read as the operator (the wallet's reads go through the gateway
// ledgerApi instead — that is the surface under test; this one is plumbing).
async function acsDirect(token, party, templateId) {
  const end = await jsonApiDirect(token, 'GET', '/v2/state/ledger-end')
  const request = {
    filter: {
      filtersByParty: {
        [party]: { cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId, includeCreatedEventBlob: false } } } }] },
      },
    },
    verbose: false,
    activeAtOffset: end.offset,
  }
  const res = await jsonApiDirect(token, 'POST', '/v2/state/active-contracts', request)
  const items = Array.isArray(res) ? res : Array.isArray(res?.body) ? res.body : []
  const contracts = []
  for (const item of items) {
    const entry = item?.contractEntry?.JsActiveContract ?? item?.contractEntry?.activeContract
    const ev = entry?.createdEvent
    if (ev) contracts.push({ contractId: ev.contractId, payload: ev.createArgument ?? ev.createArguments })
  }
  return contracts
}

const unlockedUsd = (hs) => hs.filter((h) => !h.payload?.lock && h.payload?.instrumentId?.id === 'USD')
const balanceOf = (hs, party) =>
  unlockedUsd(hs).filter((h) => h.payload?.account?.owner === party).reduce((a, h) => a + Number(h.payload.amount), 0)

async function operatorContext() {
  const { partyId: wallet } = readJson('wallet.json')
  const operator = process.env.OZ_LEDGER_OPERATOR_PARTY
  const token = await oidcToken()
  return { wallet, operator, token }
}

async function setupExternal() {
  const { wallet, operator: op, token } = await operatorContext()
  const now = new Date().toISOString()

  // Baselines for delta-based verification on a reused ledger.
  const holdings = await acsDirect(token, op, T.toyHolding)
  const receipts = await acsDirect(token, op, T.receipt)
  const baselineWalletBalance = balanceOf(holdings, wallet)
  const baselineReceiverBalance = balanceOf(holdings, op)
  const baselineSupply = unlockedUsd(holdings).reduce((a, h) => a + Number(h.payload.amount), 0)
  const baselineReceiptCount = receipts.length
  log(`baselines: wallet=${baselineWalletBalance} receiver=${baselineReceiverBalance} supply=${baselineSupply} receipts=${baselineReceiptCount}`)

  const factory = await submitAndWait(token, op, 'factory', [
    { CreateCommand: { templateId: T.factory, createArguments: { admin: op, requiresComplianceAttestation: null, featureFlag: FEATURE_FLAG } } },
  ])
  const factoryCid = createdOf(factory, 'SettlementFactory')

  const leg = transferLeg(wallet, op)
  const request = await submitAndWait(token, op, 'request', [
    { ExerciseCommand: { templateId: T.factory, contractId: factoryCid, choice: 'SettlementFactory_CreateAllocationRequest', choiceArgument: {
      authorizer: acct(wallet),
      settlement: settlementInfo(op),
      allocations: [{ admin: op, transferLegSides: [legSide('SenderSide', leg)], nextIterationFunding: null, committed: false, meta: META }],
      requestedAt: now,
      settleAt: null,
      actors: [op],
    } } },
  ])
  const requestCid = createdOf(request, 'AllocationRequest')

  const holdingOffer = await submitAndWait(token, op, 'holding-offer', [
    { CreateCommand: { templateId: T.holdingOffer, createArguments: { admin: op, owner: wallet, amount: MINT } } },
  ])
  const holdingOfferCid = createdOf(holdingOffer, 'GatewayHoldingOffer')

  const allocationOffer = await submitAndWait(token, op, 'allocation-offer', [
    { CreateCommand: { templateId: T.allocationOffer, createArguments: { admin: op, owner: wallet, app: op, receiver: op } } },
  ])
  const allocationOfferCid = createdOf(allocationOffer, 'GatewayAllocationOffer')

  const instruction = await submitAndWait(token, op, 'receiver-instruction', [
    { ExerciseCommand: { templateId: T.factory, contractId: factoryCid, choice: 'SettlementFactory_CreateAllocationInstruction', choiceArgument: {
      allocation: { settlement: settlementInfo(op), admin: op, authorizer: acct(op), transferLegSides: [legSide('ReceiverSide', leg)], nextIterationFunding: null, committed: false, meta: META },
      requestedAt: now,
      inputHoldingCids: [],
      d1ComplianceHook: null,
      actors: [op],
    } } },
  ])
  const instructionCid = createdOf(instruction, 'AllocationInstruction')
  const accepted = await submitAndWait(token, op, 'receiver-accept', [
    { ExerciseCommand: { templateId: T.instruction, contractId: instructionCid, choice: 'AllocationInstruction_Accept', choiceArgument: { actors: [op] } } },
  ])
  const receiverAllocationCid = createdOf(accepted, 'Allocation')

  writeJson('setup-output.json', {
    admin: op, app: op, receiver: op, factoryCid, requestCid, holdingOfferCid, allocationOfferCid, receiverAllocationCid,
    baselineWalletBalance, baselineReceiverBalance, baselineSupply, baselineReceiptCount,
  })
  log('external setup complete')
}

async function settleExternal() {
  const { wallet, operator: op, token } = await operatorContext()
  const setup = readJson('setup-output.json')
  const { walletAllocationCid } = readJson('gateway-output.json')
  const result = await submitAndWait(token, op, 'settle', [
    { ExerciseCommand: { templateId: T.factory, contractId: setup.factoryCid, choice: 'SettlementFactory_SettleBatch', choiceArgument: {
      settlement: settlementInfo(op),
      transferLegs: [transferLeg(wallet, op)],
      allocationCids: [walletAllocationCid, setup.receiverAllocationCid],
      actors: [op],
      d1ComplianceRef: null,
    } } },
  ])
  const receipts = result.created.filter((c) => c.templateId?.includes(':SettlementReceipt'))
  if (receipts.length !== 2) fail(`expected 2 receipts from SettleBatch, saw ${receipts.length}`)
  log(`settled batch: 2 receipts (updateId ${result.updateId})`)
}

async function verifyExternal() {
  const { wallet, operator: op, token } = await operatorContext()
  const setup = readJson('setup-output.json')
  const holdings = await acsDirect(token, op, T.toyHolding)
  const receipts = await acsDirect(token, op, T.receipt)
  const entries = await acsDirect(token, op, T.eventLog)

  const receiverDelta = balanceOf(holdings, op) - setup.baselineReceiverBalance
  if (Math.abs(receiverDelta - 25) > 1e-9) fail(`receiver balance delta ${receiverDelta}, expected +25`)
  const walletDelta = balanceOf(holdings, wallet) - setup.baselineWalletBalance
  if (Math.abs(walletDelta - 15) > 1e-9) fail(`wallet balance delta ${walletDelta}, expected +15`)
  const supplyDelta = unlockedUsd(holdings).reduce((a, h) => a + Number(h.payload.amount), 0) - setup.baselineSupply
  if (Math.abs(supplyDelta - 40) > 1e-9) fail(`supply delta ${supplyDelta}, expected +40`)
  const receiptDelta = receipts.length - setup.baselineReceiptCount
  if (receiptDelta !== 2) fail(`receipt count delta ${receiptDelta}, expected +2`)
  if (entries.length < 1) fail('expected settlement event log entries')
  log(`operator verification passed: receiver +25, wallet +15, supply +40, receipts +2, ${entries.length} event log entrie(s)`)
}

// --- subcommands -------------------------------------------------------------

// Provision the wallet user's ledger user on the participant. This is
// admin-side IAM provisioning against the sandbox, NOT part of the wallet
// surface under test; on a real network the validator operator does this.
// NOTE: the request carries no Authorization header — it assumes an auth-less
// local participant (the dev sandbox accepts unauthenticated admin calls; the
// gateway's self-signed bearer tokens are likewise not validated by it).
// Against an IAM-protected participant this call would 401 and must be
// replaced by the operator's own user-provisioning flow.
async function ensureLedgerUser(userId) {
  const res = await fetch(`${JSON_API}/v2/users`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      user: { id: userId, primaryParty: '', isDeactivated: false, identityProviderId: '' },
      rights: [],
    }),
  })
  if (res.ok) {
    log(`provisioned ledger user ${userId}`)
    return
  }
  const text = await res.text()
  if (res.status === 409 || text.includes('ALREADY_EXISTS')) {
    log(`ledger user ${userId} already exists`)
    return
  }
  throw new Error(`failed to create ledger user ${userId}: HTTP ${res.status}: ${text.slice(0, 400)}`)
}

// External mode (devnet/testnet): mint a real OIDC access token with the
// client-credentials grant. All identifiers and secrets come from the
// environment — nothing network-specific lives in the repo.
async function oidcToken() {
  const res = await fetch(process.env.OZ_OIDC_TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'client_credentials',
      client_id: process.env.OZ_OIDC_CLIENT_ID,
      client_secret: process.env.OZ_OIDC_CLIENT_SECRET,
      audience: process.env.OZ_OIDC_AUDIENCE,
    }),
  })
  if (!res.ok) throw new Error(`OIDC token request failed: HTTP ${res.status}`)
  const { access_token: accessToken } = await res.json()
  if (!accessToken) throw new Error('OIDC token response carried no access_token')
  return accessToken
}

// External mode: the runner cannot allocate parties, so instead of
// createWallet (which allocates an externally-signed party) the gateway
// ADOPTS the pre-allocated participant-local party the token can act as:
// addSession auto-syncs the user's ledger parties into gateway wallets with
// the `participant` signing provider, and the flow proceeds through the same
// CIP-0103 surfaces with participant-side signing.
async function createWalletExternal() {
  const partyId = process.env.OZ_LEDGER_PARTY
  const operator = process.env.OZ_LEDGER_OPERATOR_PARTY
  if (!partyId || !operator) fail('external mode requires OZ_LEDGER_PARTY and OZ_LEDGER_OPERATOR_PARTY')
  log(`user API: ${USER_API}, network: ${NETWORK_ID} (external ledger)`)
  const accessToken = await oidcToken()
  log('obtained OIDC access token (client_credentials)')
  await rpc(USER_API, 'addSession', { networkId: NETWORK_ID }, accessToken)
  log('session added')
  await rpc(USER_API, 'syncWallets', undefined, accessToken).catch((err) => log(`syncWallets: ${err.message}`))
  const wallet = await poll(`gateway wallet for ${partyId}`, 60_000, 500, async () => {
    const wallets = await rpc(USER_API, 'listWallets', {}, accessToken)
    const list = Array.isArray(wallets) ? wallets : wallets.wallets
    return list.find((w) => w.partyId === partyId)
  })
  if (!wallet.primary) {
    await rpc(USER_API, 'setPrimaryWallet', { partyId }, accessToken)
    log('marked wallet primary')
  }
  log(`gateway adopted wallet party: ${wallet.partyId} (signing: ${wallet.signingProviderId})`)
  writeJson('wallet.json', { partyId, accessToken })
  writeJson('setup-input.json', { wallet: partyId, operator })
}

async function createWallet() {
  if (EXTERNAL) return createWalletExternal()
  log(`user API: ${USER_API}, network: ${NETWORK_ID}`)
  await ensureLedgerUser(LEDGER_USER)
  const { accessToken } = await rpc(USER_API, 'selfSignedAccessToken', {
    networkId: NETWORK_ID,
    clientId: LEDGER_USER,
  })
  log('obtained self-signed access token')
  await rpc(USER_API, 'addSession', { networkId: NETWORK_ID }, accessToken)
  log('session added')
  const created = await rpc(
    USER_API,
    'createWallet',
    { primary: true, partyHint: 'oz-cip0103-wallet', signingProviderId: 'wallet-kernel' },
    accessToken
  )
  log(`createWallet: ${created.wallet.partyId} (status ${created.wallet.status})`)
  const wallet = await poll('wallet party allocation', 60_000, 500, async () => {
    const wallets = await rpc(USER_API, 'listWallets', {}, accessToken)
    const list = Array.isArray(wallets) ? wallets : wallets.wallets
    return list.find((w) => w.partyId === created.wallet.partyId && w.status === 'allocated')
  })
  log(`wallet party allocated: ${wallet.partyId}`)
  writeJson('wallet.json', { partyId: wallet.partyId, accessToken })
  // Also emit the Daml Script input for the setup phase.
  writeJson('setup-input.json', wallet.partyId)
}

async function dappFlow() {
  const { partyId, accessToken } = readJson('wallet.json')
  const setup = readJson('setup-output.json')

  // CIP-0103 session surface.
  const connect = await rpc(DAPP_API, 'connect', {}, accessToken)
  log(`connect: ${JSON.stringify(connect)}`)
  if (connect.isConnected === false) fail(`gateway session not connected: ${JSON.stringify(connect)}`)
  const status = await rpc(DAPP_API, 'status', {}, accessToken)
  log(`status: ${JSON.stringify(status)}`)
  const accounts = await rpc(DAPP_API, 'listAccounts', {}, accessToken)
  const accountList = Array.isArray(accounts) ? accounts : accounts.accounts
  const mine = accountList.find((a) => a.partyId === partyId)
  if (!mine) fail(`listAccounts does not include wallet party ${partyId}`)
  log(`listAccounts includes wallet party (primary=${mine.primary})`)

  // Baselines: a shared external ledger accumulates state across runs, so all
  // post-settlement checks are deltas against what the wallet sees now.
  const isUnlocked = (h) => !h.payload?.lock
  const unlockedBalance = (hs) => hs.filter(isUnlocked).reduce((acc, h) => acc + Number(h.payload?.amount ?? 0), 0)
  const preHoldings = await acs(accessToken, partyId, T.toyHolding)
  const baseline = {
    receipts: (await acs(accessToken, partyId, T.receipt)).length,
    eventLogEntries: (await acs(accessToken, partyId, T.eventLog)).length,
    unlockedBalance: unlockedBalance(preHoldings),
  }
  const preHoldingCids = new Set(preHoldings.map((h) => h.contractId))
  log(`baselines: ${JSON.stringify(baseline)}`)

  const sse = listenTxChanged(accessToken)

  // 1. Wallet receives its funding holding (propose-accept mint).
  await exerciseViaGateway(accessToken, partyId, 'holding-offer', T.holdingOffer, setup.holdingOfferCid, 'GatewayHoldingOffer_Accept', {})
  const minted = await poll('freshly minted wallet ToyHolding in ACS', 30_000, 500, async () => {
    const hs = await acs(accessToken, partyId, T.toyHolding)
    const fresh = hs.filter((h) => !preHoldingCids.has(h.contractId) && isUnlocked(h) && Number(h.payload?.amount ?? 0) === 40)
    return fresh.length > 0 ? fresh : undefined
  })
  const holdingCid = minted[0].contractId
  log(`wallet holding: ${holdingCid}`)

  // 2. Wallet accepts the app's CIP-0103 allocation request.
  await exerciseViaGateway(accessToken, partyId, 'allocation-request', T.allocationRequest, setup.requestCid, 'AllocationRequest_Accept', { actors: [partyId] })

  // 3. Wallet funds and accepts the sender-side allocation.
  const preAllocations = new Set((await acs(accessToken, partyId, T.allocation)).map((a) => a.contractId))
  await exerciseViaGateway(accessToken, partyId, 'allocation-offer', T.allocationOffer, setup.allocationOfferCid, 'GatewayAllocationOffer_Accept', { holdingCids: [holdingCid] })
  const allocations = await poll('wallet Allocation in ACS', 30_000, 500, async () => {
    const as = (await acs(accessToken, partyId, T.allocation)).filter((a) => !preAllocations.has(a.contractId))
    return as.length > 0 ? as : undefined
  })
  const walletAllocationCid = allocations[0].contractId
  log(`wallet allocation: ${walletAllocationCid}`)

  // Pre-settlement: this run's settlement must not have produced receipts yet.
  const preReceipts = await acs(accessToken, partyId, T.receipt)
  if (preReceipts.length !== baseline.receipts) {
    fail(`expected ${baseline.receipts} receipts before settlement, saw ${preReceipts.length}`)
  }

  // SSE frames are delivered asynchronously: the user-API poll above only
  // guarantees each transaction executed, not that its `executed` frame has
  // arrived. Drain the stream until all three frames are in before stopping.
  const collectTxEvents = () =>
    sse.events
      .flatMap((e) => (Array.isArray(e.data) ? e.data : [e.data]))
      .filter((d) => d && typeof d === 'object' && d.status)
      .map((d) => ({ status: d.status, commandId: d.commandId, ...(d.payload ? { payload: d.payload } : {}) }))
  await poll('3 executed txChanged frames', 30_000, 200, () =>
    collectTxEvents().filter((e) => e.status === 'executed').length >= 3 ? true : undefined
  )
  await sse.stop()
  const txEvents = collectTxEvents()
  log(`txChanged events observed: ${txEvents.length}`)
  for (const e of txEvents) log(`  ${JSON.stringify(e)}`)

  writeJson('gateway-output.json', { walletAllocationCid, baseline, txChangedEvents: txEvents })
  writeJson('settle-input.json', {
    admin: setup.admin,
    app: setup.app,
    wallet: partyId,
    receiver: setup.receiver,
    factoryCid: setup.factoryCid,
    walletAllocationCid,
    receiverAllocationCid: setup.receiverAllocationCid,
  })
  writeJson('verify-input.json', {
    admin: setup.admin,
    app: setup.app,
    wallet: partyId,
    receiver: setup.receiver,
    baselineWalletBalance: setup.baselineWalletBalance,
    baselineReceiverBalance: setup.baselineReceiverBalance,
    baselineSupply: setup.baselineSupply,
    baselineReceiptCount: setup.baselineReceiptCount,
  })
}

async function verifyWalletView() {
  const { partyId, accessToken } = readJson('wallet.json')
  const { baseline } = readJson('gateway-output.json')

  const receipts = await acs(accessToken, partyId, T.receipt)
  if (receipts.length < baseline.receipts + 1) {
    fail(`wallet sees ${receipts.length} settlement receipts, expected >= ${baseline.receipts + 1}`)
  }
  log(`wallet sees ${receipts.length - baseline.receipts} new settlement receipt(s) via gateway ledgerApi`)

  const entries = await acs(accessToken, partyId, T.eventLog)
  if (entries.length < baseline.eventLogEntries + 1) {
    fail(`wallet sees ${entries.length} event log entries, expected >= ${baseline.eventLogEntries + 1}`)
  }
  log(`wallet sees ${entries.length - baseline.eventLogEntries} new settlement event log entrie(s)`)

  const holdings = await acs(accessToken, partyId, T.toyHolding)
  const unlocked = holdings.filter((h) => !h.payload?.lock)
  const balance = unlocked.reduce((acc, h) => acc + Number(h.payload?.amount ?? 0), 0)
  const delta = balance - baseline.unlockedBalance
  if (Math.abs(delta - 15) > 1e-9) fail(`wallet balance delta is ${delta}, expected +15 (minted 40, sent 25)`)
  log(`wallet balance delta is +15.0 as expected`)

  log('wallet-view verification passed')
}

const command = process.argv[2]
const commands = {
  'create-wallet': createWallet,
  'dapp-flow': dappFlow,
  'verify-wallet-view': verifyWalletView,
  'setup-external': setupExternal,
  'settle-external': settleExternal,
  'verify-external': verifyExternal,
}
if (!commands[command]) {
  console.error(`usage: harness.mjs <${Object.keys(commands).join('|')}>`)
  process.exit(2)
}
commands[command]().catch((err) => fail(err.stack ?? String(err)))
