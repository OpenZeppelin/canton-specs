#!/usr/bin/env node
// CIP-0104 traffic-based app rewards on Canton LocalNet.
//
// The client features the app-provider party, switches the network to
// traffic-based app rewards, settles CIP-0112 batches as the featured
// app-provider, and then follows the reward that the network computes from the
// traffic of those settlements. The settlement packages get no CIP-0104 code:
// the sequencer measures the traffic, Scan attributes it to the
// `FeaturedAppRight` holders of each transaction, and the SV mints a
// `RewardCouponV2` for the app-provider when the round closes.
//
// The client then assigns beneficiaries to that coupon
// (`RewardCoupon_AssignBeneficiaries`), which is where an app divides its reward.
// The assignment replaces the coupon with one coupon for each beneficiary, and
// the client asserts those coupons. Collection of a coupon into Canton Coin is
// validator-wallet automation on its own schedule, and it is outside this client.
//
// `scripts/localnet-cip0104-traffic-rewards.sh` starts the LocalNet that this
// client needs and then this client.
//
// The run changes the network, and nothing reverts those changes: the featured
// app right, the reward configuration, the lowered coupon threshold, and the
// party rights all stay. The gate founds and removes its own LocalNet, so the
// changes go with that network. `OZ_USE_EXTERNAL_LEDGER=1` keeps them, thus point
// that mode at a disposable network.
//
// Environment:
//   OZ_JSON_API_URL          JSON Ledger API of the app-provider participant
//   OZ_LEDGER_TOKEN_FILE     file with the token of the participant admin user
//   OZ_LEDGER_TOKEN          the same token, given directly
//   OZ_LEDGER_USER_ID        Ledger API user that the client submits as
//   OZ_VALIDATOR_API_URL     validator (wallet) API of the app-provider
//   OZ_SV_API_URL            SV app API
//   OZ_SCAN_API_URL          Scan API
//   OZ_LOCALNET_AUTH_SECRET  HS256 secret that the Splice apps accept
//   OZ_LOCALNET_AUTH_AUDIENCE  audience that the Splice apps accept
//   OZ_WALLET_ADMIN_USER     wallet admin user of the app-provider validator
//   OZ_SV_USER               wallet admin user of the SV
//   OZ_REWARD_TIMEOUT_S      seconds to wait for the round and the coupon
//   OZ_TRAFFIC_TIMEOUT_S     seconds to wait for validator traffic and a round
//   OZ_EVIDENCE_FILE         file for the JSON evidence of the run

import { readFileSync, writeFileSync } from 'node:fs'
import { createHmac } from 'node:crypto'

const trimSlash = (url) => url.replace(/\/+$/, '')

const JSON_API = trimSlash(process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:3975')
const VALIDATOR_API = trimSlash(process.env.OZ_VALIDATOR_API_URL ?? 'http://wallet.localhost:3000/api/validator')
const SV_API = trimSlash(process.env.OZ_SV_API_URL ?? 'http://sv.localhost:4000/api/sv')
const SCAN_API = trimSlash(process.env.OZ_SCAN_API_URL ?? 'http://scan.localhost:4000/api/scan')

const AUTH_SECRET = process.env.OZ_LOCALNET_AUTH_SECRET ?? 'unsafe'
const AUTH_AUDIENCE = process.env.OZ_LOCALNET_AUTH_AUDIENCE ?? 'https://canton.network.global'
const WALLET_ADMIN_USER = process.env.OZ_WALLET_ADMIN_USER ?? 'app-provider'
const SV_USER = process.env.OZ_SV_USER ?? 'sv'
const LEDGER_USER = process.env.OZ_LEDGER_USER_ID ?? 'ledger-api-user'
const EVIDENCE_FILE = process.env.OZ_EVIDENCE_FILE ?? null

// The reward loop waits for the network: a round must close, Scan must compute
// its totals, and the SV must confirm them. The gate shortens the round, so
// this timeout covers several rounds of a shortened network.
const REWARD_TIMEOUT_MS = Number(process.env.OZ_REWARD_TIMEOUT_S ?? 900) * 1000
// A fresh app-provider validator holds no synchronizer traffic. It buys traffic
// from the SV on its own interval, so the first call that costs traffic waits.
const TRAFFIC_TIMEOUT_MS = Number(process.env.OZ_TRAFFIC_TIMEOUT_S ?? 300) * 1000
const POLL_INTERVAL_MS = 5000

// The token of the participant admin user. The gate mints it, because the same
// token carries the Daml Script runs of the other LocalNet gates.
const LEDGER_TOKEN =
  process.env.OZ_LEDGER_TOKEN ??
  (process.env.OZ_LEDGER_TOKEN_FILE ? readFileSync(process.env.OZ_LEDGER_TOKEN_FILE, 'utf8').trim() : null)

const PKG_SETTLEMENT = '#openzeppelin-experimental-cip112-settlement'
const MOD_ENGINE = 'OpenZeppelin.Experimental.Settlement.Cip112'
const T = {
  factory: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementFactory`,
  instruction: `${PKG_SETTLEMENT}:${MOD_ENGINE}:AllocationInstruction`,
  toyHolding: `${PKG_SETTLEMENT}:${MOD_ENGINE}:ToyHolding`,
  receipt: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementReceipt`,
  // Splice packages, which LocalNet vets on the app-provider participant.
  rewardCouponV2: '#splice-amulet:Splice.Amulet:RewardCouponV2',
  rewardCoupon: '#splice-api-reward-assignment-v1:Splice.Api.RewardAssignmentV1:RewardCoupon',
}

const FEATURE_FLAG = 'experimental.cip112-settlement.enabled'
const META = { entries: [] }
// The `ExtraArgs` of the Splice token metadata API: an empty choice context and
// empty metadata.
const EXTRA_ARGS = { context: { values: {} }, meta: { values: {} } }
const EPS = 1e-8

// The beneficiary split that the app-provider assigns to its coupon. The
// percentages must add up to exactly 1.0, and a coupon takes a maximum of 20
// beneficiaries.
const BENEFICIARY_SPLIT = [
  ['venue', '0.7'],
  ['registrar', '0.2'],
  ['operator', '0.1'],
]

const log = (...args) => console.log('[traffic-rewards]', ...args)

const fail = (msg) => {
  console.error('[traffic-rewards] FAIL:', msg)
  process.exit(1)
}

const assertEq = (label, actual, expected) => {
  const ok = typeof expected === 'number' ? Math.abs(actual - expected) < EPS : actual === expected
  if (!ok) fail(`${label}: expected ${expected}, saw ${actual}`)
}

const assertTrue = (label, cond) => {
  if (!cond) fail(label)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// --- HTTP --------------------------------------------------------------------

async function http(method, url, { token = null, body = undefined, label = url } = {}) {
  const res = await fetch(url, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  if (!res.ok) {
    const err = new Error(`${method} ${label}: HTTP ${res.status}: ${text.slice(0, 500)}`)
    err.status = res.status
    err.body = text
    throw err
  }
  return text ? JSON.parse(text) : undefined
}

// LocalNet publishes the SV app, Scan, and the wallet API behind one nginx that
// routes on the `Host` header, and the first server block of the port answers
// every name that it does not know. A name that does not resolve therefore gives
// a 404 from the wrong service, so the run stops before that.
async function requireResolvableHosts() {
  const { lookup } = await import('node:dns/promises')
  for (const url of [VALIDATOR_API, SV_API, SCAN_API]) {
    const { hostname } = new URL(url)
    try {
      await lookup(hostname)
    } catch (err) {
      fail(
        `${hostname} does not resolve (${err.code}). Add "127.0.0.1 ${hostname}" to /etc/hosts, ` +
          'or point OZ_VALIDATOR_API_URL, OZ_SV_API_URL, and OZ_SCAN_API_URL at names that resolve.',
      )
    }
  }
}

// A LocalNet Splice app authenticates with an unsafe HS256 secret, so the
// client mints its own token for each app user that it calls as.
function spliceToken(subject) {
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url')
  const header = b64({ alg: 'HS256', typ: 'JWT' })
  const payload = b64({ sub: subject, aud: AUTH_AUDIENCE })
  const signature = createHmac('sha256', AUTH_SECRET).update(`${header}.${payload}`).digest('base64url')
  return `${header}.${payload}.${signature}`
}

const walletApi = (method, path, body) =>
  http(method, `${VALIDATOR_API}${path}`, { token: spliceToken(WALLET_ADMIN_USER), body, label: `validator ${path}` })
const svApi = (method, path, body) =>
  http(method, `${SV_API}${path}`, { token: spliceToken(SV_USER), body, label: `sv ${path}` })
const scanApi = (method, path, body) => http(method, `${SCAN_API}${path}`, { body, label: `scan ${path}` })
const ledgerApi = (method, path, body) =>
  http(method, `${JSON_API}${path}`, { token: LEDGER_TOKEN, body, label: `ledger ${path}` })

// Poll until `probe` returns a value that is not null or undefined.
async function waitFor(label, probe, timeoutMs = REWARD_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs
  let attempts = 0
  for (;;) {
    const result = await probe()
    if (result !== null && result !== undefined) return result
    attempts += 1
    if (Date.now() >= deadline) {
      fail(`${label}: no result after ${Math.round(timeoutMs / 1000)}s (${attempts} attempts)`)
    }
    if (attempts % 6 === 0) log(`still waiting for ${label} (${attempts * (POLL_INTERVAL_MS / 1000)}s)`)
    await sleep(POLL_INTERVAL_MS)
  }
}

// --- Ledger API --------------------------------------------------------------

async function allocateParty(hint) {
  const res = await ledgerApi('POST', '/v2/parties', { partyIdHint: hint, identityProviderId: '' })
  const party = res?.partyDetails?.party ?? res?.party
  if (!party) throw new Error(`party allocation for ${hint} gave no party`)
  return party
}

// Each submission carries a user id, and that user may submit for a party only
// if a `CanActAs` right names the party. Party allocation grants no right, and
// the app-provider party belongs to the validator, so the client grants the
// rights that it needs to the admin user that it submits as. On a real network
// the validator operator does this setup through its IAM.
async function grantActAs(parties) {
  const rights = parties.map((party) => ({ kind: { CanActAs: { value: { party } } } }))
  await ledgerApi('POST', `/v2/users/${LEDGER_USER}/rights`, {
    userId: LEDGER_USER,
    rights,
    identityProviderId: '',
  })
}

let cmdSeq = 0
async function submit(actAs, label, commands, { disclosedContracts, mustFail = null } = {}) {
  const commandId = `oz-traffic-rewards-${label}-${++cmdSeq}`
  try {
    const res = await ledgerApi('POST', '/v2/commands/submit-and-wait-for-transaction', {
      commands: { userId: LEDGER_USER, commands, commandId, actAs, ...(disclosedContracts ? { disclosedContracts } : {}) },
    })
    if (mustFail) fail(`${label}: expected the submission to fail, but it succeeded`)
    const created = []
    for (const e of res?.transaction?.events ?? []) {
      const ev = e?.CreatedEvent ?? e?.created ?? e?.CreatedTreeEvent?.value
      if (ev) created.push({ contractId: ev.contractId, templateId: ev.templateId })
    }
    // The record time decides which mining round accounts for the traffic of
    // this transaction.
    return { created, recordTime: res?.transaction?.recordTime }
  } catch (err) {
    if (!mustFail) throw err
    const body = err.body ?? String(err.message)
    if (!body.includes(mustFail)) throw err
    log(`${label}: rejected as expected`)
    return null
  }
}

const createdOf = (result, entity) => {
  const hit = result.created.find((c) => c.templateId?.endsWith(`:${entity}`))
  if (!hit) throw new Error(`no created ${entity}; created: ${result.created.map((c) => c.templateId).join(', ')}`)
  return hit.contractId
}

// Read the active contracts of one template, as `party` sees them. Set
// `withBlob` to also get the created-event blob, which lets the caller give the
// contract to an other party as a disclosed contract.
async function acs(party, templateId, { withBlob = false } = {}) {
  const end = await ledgerApi('GET', '/v2/state/ledger-end')
  const res = await ledgerApi('POST', '/v2/state/active-contracts', {
    filter: {
      filtersByParty: {
        [party]: {
          cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId, includeCreatedEventBlob: withBlob } } } }],
        },
      },
    },
    verbose: false,
    activeAtOffset: end.offset,
  })
  const items = Array.isArray(res) ? res : Array.isArray(res?.body) ? res.body : []
  const contracts = []
  for (const item of items) {
    const entry = item?.contractEntry?.JsActiveContract ?? item?.contractEntry?.activeContract
    const ev = entry?.createdEvent
    if (ev) {
      contracts.push({
        contractId: ev.contractId,
        templateId: ev.templateId,
        payload: ev.createArgument ?? ev.createArguments,
        createdEventBlob: ev.createdEventBlob,
        synchronizerId: entry.synchronizerId,
      })
    }
  }
  if (items.length > 0 && contracts.length === 0) {
    throw new Error(`active-contracts: ${items.length} entries but none parseable`)
  }
  return contracts
}

// --- settlement surface (the traffic that the reward is computed from) -------

const acct = (p) => ({ owner: p, provider: null, id: '' })
// Wallclock ledger: these settlements have no deadline.
const settlementInfo = (ref, app) => ({
  executors: [app],
  settlementRef: { id: ref, cidText: null },
  settlementDeadline: null,
  meta: META,
})
const transferLeg = (ref, sender, receiver, amount) => ({
  transferLegId: `${ref}-leg`,
  sender: acct(sender),
  receiver: acct(receiver),
  amount: String(amount),
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

async function mintUsd(admin, owner, amount) {
  const res = await submit([admin, owner], 'mint', [
    { CreateCommand: { templateId: T.toyHolding, createArguments: {
      admin,
      account: acct(owner),
      instrumentId: { admin, id: 'USD' },
      amount: String(amount),
      lock: null,
      meta: META,
      featureFlag: FEATURE_FLAG,
    } } },
  ])
  return createdOf(res, 'ToyHolding')
}

// The executor is not a stakeholder of the factory, so the client reads the
// factory back with its created-event blob and gives it to the executor as a
// disclosed contract.
async function mkFactory(admin) {
  const res = await submit([admin], 'factory', [
    { CreateCommand: { templateId: T.factory, createArguments: { admin, requiresComplianceAttestation: null, featureFlag: FEATURE_FLAG } } },
  ])
  const factoryCid = createdOf(res, 'SettlementFactory')
  const withBlob = (await acs(admin, T.factory, { withBlob: true })).find((c) => c.contractId === factoryCid)
  if (!withBlob?.createdEventBlob) throw new Error('factory created-event blob not found for disclosure')
  return {
    factoryCid,
    disclosure: {
      templateId: withBlob.templateId,
      contractId: withBlob.contractId,
      createdEventBlob: withBlob.createdEventBlob,
      synchronizerId: withBlob.synchronizerId,
    },
  }
}

async function createAndAcceptAllocation(admin, factory, settlement, authorizer, sides, inputHoldingCids) {
  const actors = [authorizer]
  const instruction = await submit(actors, 'instruction', [
    { ExerciseCommand: { templateId: T.factory, contractId: factory.factoryCid, choice: 'SettlementFactory_CreateAllocationInstruction', choiceArgument: {
      allocation: { settlement, admin, authorizer: acct(authorizer), transferLegSides: sides, nextIterationFunding: null, committed: false, meta: META },
      requestedAt: new Date().toISOString(),
      inputHoldingCids,
      d1ComplianceHook: null,
      actors,
    } } },
  ], { disclosedContracts: [factory.disclosure] })
  const instructionCid = createdOf(instruction, 'AllocationInstruction')
  const accepted = await submit(actors, 'accept', [
    { ExerciseCommand: { templateId: T.instruction, contractId: instructionCid, choice: 'AllocationInstruction_Accept', choiceArgument: { actors } } },
  ])
  return createdOf(accepted, 'Allocation')
}

// One settlement, executed by the featured app-provider. Every command of this
// function costs traffic, and CIP-0104 attributes the traffic of the settle
// transaction to the app-provider that confirms it.
// Returns the record time of the settle transaction, which is the transaction
// whose traffic CIP-0104 attributes to the app-provider that confirms it.
async function settleUsdTransfer(admin, app, sender, receiver, senderHoldingCid, amount, ref) {
  const factory = await mkFactory(admin)
  const settlement = settlementInfo(ref, app)
  const leg = transferLeg(ref, sender, receiver, amount)
  const senderAlloc = await createAndAcceptAllocation(admin, factory, settlement, sender, [legSide('SenderSide', leg)], [senderHoldingCid])
  const receiverAlloc = await createAndAcceptAllocation(admin, factory, settlement, receiver, [legSide('ReceiverSide', leg)], [])
  const settled = await submit([app], 'settle', [
    { ExerciseCommand: { templateId: T.factory, contractId: factory.factoryCid, choice: 'SettlementFactory_SettleBatch', choiceArgument: {
      settlement, transferLegs: [leg], allocationCids: [senderAlloc, receiverAlloc], actors: [app], d1ComplianceRef: null,
    } } },
  ], { disclosedContracts: [factory.disclosure] })
  return settled.recordTime
}

const unlockedUsd = (hs) => hs.filter((h) => !h.payload?.lock && h.payload?.instrumentId?.id === 'USD')

async function holdingWithAmount(admin, owner, amount) {
  const holdings = await acs(admin, T.toyHolding)
  const hit = unlockedUsd(holdings).find(
    (h) => h.payload.account.owner === owner && Math.abs(Number(h.payload.amount) - amount) < EPS,
  )
  if (!hit) throw new Error(`no unlocked holding of ${amount} found for ${owner.slice(0, 24)}...`)
  return hit.contractId
}

// The settlements that the app-provider confirmed as executor. This is the
// app-side attribution surface that `SettlementAttribution.daml` specifies, and
// the client checks it before it waits for the network to measure the traffic
// of the same settlements.
async function attributedActivity(app) {
  const receipts = (await acs(app, T.receipt)).filter((r) => (r.payload.settlement.executors ?? []).includes(app))
  const refs = new Set(receipts.map((r) => r.payload.settlement.settlementRef.id))
  const settledVolume = receipts
    .flatMap((r) => r.payload.settledTransferLegSides ?? [])
    .filter((s) => s.side === 'SenderSide' && s.instrumentId === 'USD')
    .reduce((a, s) => a + Number(s.amount), 0)
  return { settlements: refs.size, settledVolume }
}

// --- Splice: featuring, reward configuration, rewards ------------------------

// LocalNet runs with `SPLICE_SV_IS_DEVNET=true`, so the app-provider grants
// itself the `FeaturedAppRight` that CIP-0078 requires for any app reward. On
// TestNet and MainNet the Canton Foundation grants it instead.
async function selfFeature() {
  const status = await waitFor(
    'the wallet of the app-provider',
    async () => {
      const current = await walletApi('GET', '/v0/wallet/user-status')
      return current.user_onboarded && current.user_wallet_installed ? current : null
    },
    TRAFFIC_TIMEOUT_MS,
  )
  if (!status.has_featured_app_right) {
    // A fresh validator holds no synchronizer traffic and buys it from the SV on
    // its own interval, and it answers 429 until then.
    const granted = await waitFor(
      'synchronizer traffic for the app-provider validator',
      async () => {
        try {
          return await walletApi('POST', '/v0/wallet/self-grant-feature-app-right', {})
        } catch (err) {
          if (err.status === 429) return null
          throw err
        }
      },
      TRAFFIC_TIMEOUT_MS,
    )
    log(`self-granted the featured app right (${granted.contract_id.slice(0, 16)}...)`)
  } else {
    log('the app-provider already holds a featured app right')
  }
  const featured = await scanApi('GET', '/v0/featured-apps')
  const mine = (featured.featured_apps ?? []).filter((a) => a.payload?.provider === status.party_id)
  assertEq('Scan reports one featured app right for the app-provider', mine.length, 1)
  return status.party_id
}

const trafficRewardConfig = (rewardCouponThreshold) => ({
  mintingVersion: 'RewardVersion_TrafficBasedAppRewards',
  dryRunVersion: null,
  batchSize: '100',
  rewardCouponTimeToLive: { microseconds: String(36 * 3600 * 1000000) },
  // The threshold drops far below its 0.5 USD default: the traffic of this run
  // is small, and a round below the threshold mints no coupon at all.
  appRewardCouponThreshold: rewardCouponThreshold,
})

// The mining version is a governance decision, so switching it needs an SV
// vote. LocalNet has one SV and a voting threshold of 1, so the vote of the
// requester carries. The action is the Daml `ARC_AmuletRules` /
// `CRARC_SetConfig` value, and the base config comes from Scan.
async function enableTrafficBasedRewards() {
  const dso = await scanApi('GET', '/v0/dso')
  const base = dso.amulet_rules.contract.payload.configSchedule.initialValue
  if (base.rewardConfig?.mintingVersion === 'RewardVersion_TrafficBasedAppRewards') {
    log('the network already runs traffic-based app rewards')
    return
  }
  assertEq('the SV voting threshold is 1', Number(dso.voting_threshold), 1)
  const newConfig = { ...structuredClone(base), rewardConfig: trafficRewardConfig('0.0000000001') }
  await svApi('POST', '/v0/admin/sv/voterequest/create', {
    requester: dso.sv_party_id,
    action: {
      tag: 'ARC_AmuletRules',
      value: { amuletRulesAction: { tag: 'CRARC_SetConfig', value: { newConfig, baseConfig: base } } },
    },
    url: 'https://github.com/OpenZeppelin/canton-specs',
    description: 'enable CIP-0104 traffic-based app rewards for the interoperability gate',
    expiration: { microseconds: String(24 * 3600 * 1000000) },
  })
  log('requested the vote that enables traffic-based app rewards')
  await waitFor('the traffic-based reward configuration', async () => {
    const current = await scanApi('GET', '/v0/dso')
    const cfg = current.amulet_rules.contract.payload.configSchedule.initialValue.rewardConfig
    return cfg?.mintingVersion === 'RewardVersion_TrafficBasedAppRewards' ? cfg : null
  })
  log('the network runs traffic-based app rewards')
}

const latestRound = async () => {
  const dso = await scanApi('GET', '/v0/dso')
  return Number(dso.latest_mining_round.contract.payload.round.number)
}

// Splice keeps several mining rounds open at once and fills its reward accounting
// behind them. Which round accounts for the traffic of a transaction is internal
// to Splice, and the CIP-0104 endpoints of Scan carry a "subject to change" note,
// so the client makes no assumption about it: it searches forward from the round
// that it saw before its settlements.
async function waitForAttributedRound(fromRound, provider) {
  return waitFor('a round that rewards the app-provider', async () => {
    const latest = await latestRound()
    for (let round = fromRound; round <= latest; round += 1) {
      const totals = await scanApi(
        'GET',
        `/v0/internal/reward-accounting-process/rounds/${round}/activity-totals`,
      )
      if (totals.status !== 'Ok') continue
      if (Number(totals.total_app_activity_weight) <= 0) continue
      const allowances = await roundMintingAllowances(round)
      const mine = allowances.filter((a) => a.provider === provider)
      if (mine.length === 1) return { round, totals, allowance: mine[0].amount }
    }
    return null
  })
}

// The minting allowances that Scan computed for the round. This is the leaf of
// the Merkle tree that the SV confirms, so it names the parties that the round
// pays.
async function roundMintingAllowances(round) {
  const hash = await scanApi('GET', `/v0/internal/reward-accounting-process/rounds/${round}/root-hash`)
  assertEq(`the root hash of round ${round}`, hash.status, 'Ok')
  const batch = await scanApi(
    'GET',
    `/v0/internal/reward-accounting-process/rounds/${round}/batches/${hash.root_hash}`,
  )
  return batch.minting_allowances ?? []
}

const couponsOf = async (provider) =>
  (await acs(provider, T.rewardCouponV2)).filter((c) => c.payload.provider === provider)

// The SV creates one `RewardCouponV2` for each rewarded provider of a round. The
// client takes the coupon of the round that it measured, and only a coupon
// without a beneficiary accepts an assignment. A provider that earns in several
// rounds holds several coupons, so the round keeps the coupon and the measured
// activity together.
async function waitForUnassignedCoupon(provider, round) {
  return waitFor(`the reward coupon of round ${round}`, async () => {
    const coupons = await couponsOf(provider)
    return (
      coupons.find((c) => !c.payload.beneficiary && String(c.payload.round.number) === String(round)) ?? null
    )
  })
}

// Divide the reward: the provider assigns its beneficiaries and their
// percentages. The choice archives the coupon and creates one coupon for each
// beneficiary, with the amount scaled by the percentage.
async function assignBeneficiaries(provider, couponCid, beneficiaries) {
  await submit([provider], 'assign-beneficiaries', [
    { ExerciseCommand: { templateId: T.rewardCoupon, contractId: couponCid, choice: 'RewardCoupon_AssignBeneficiaries', choiceArgument: {
      additionalCoupons: [],
      newBeneficiaries: beneficiaries.map(([beneficiary, percentage]) => ({ beneficiary, percentage })),
      extraArgs: EXTRA_ARGS,
    } } },
  ])
}

// --- the run -----------------------------------------------------------------

// A party id hint must be unique on the participant. The gate always founds a
// fresh network, and the suffix also keeps a repeated run against a kept
// network from colliding.
const RUN_ID = Date.now().toString(36)

async function main() {
  if (!LEDGER_TOKEN) fail('this gate needs the participant admin token (OZ_LEDGER_TOKEN_FILE or OZ_LEDGER_TOKEN)')
  log(`JSON Ledger API ${JSON_API}, validator ${VALIDATOR_API}, SV ${SV_API}, Scan ${SCAN_API} (run ${RUN_ID})`)
  await requireResolvableHosts()

  // Step 1: the app-provider becomes a featured app.
  const provider = await selfFeature()
  log(`app-provider party: ${provider}`)

  // Step 2: the network switches to traffic-based app rewards.
  await enableTrafficBasedRewards()

  // Step 3: the settlement parties. The app-provider executes every settlement,
  // so the admin user that this client submits as needs `CanActAs` for the
  // app-provider party too.
  const [admin, alice, bob, registrar, operator] = await Promise.all([
    allocateParty(`traffic-admin-${RUN_ID}`),
    allocateParty(`traffic-alice-${RUN_ID}`),
    allocateParty(`traffic-bob-${RUN_ID}`),
    allocateParty(`traffic-registrar-${RUN_ID}`),
    allocateParty(`traffic-operator-${RUN_ID}`),
  ])
  await grantActAs([provider, admin, alice, bob, registrar, operator])

  const roundBefore = await latestRound()
  log(`starting at round ${roundBefore}`)

  // Step 4: the traffic. The app-provider settles three CIP-0112 batches as the
  // executor. No command here mentions CIP-0104. The record times go into the
  // evidence, because they state when the traffic of the run reached the ledger.
  const aliceHolding = await mintUsd(admin, alice, 100.0)
  const recordTimes = []
  recordTimes.push(await settleUsdTransfer(admin, provider, alice, bob, aliceHolding, 30.0, `traffic-${RUN_ID}-1`))
  const bobHolding = await holdingWithAmount(admin, bob, 30.0)
  recordTimes.push(await settleUsdTransfer(admin, provider, bob, alice, bobHolding, 10.0, `traffic-${RUN_ID}-2`))
  const aliceHolding2 = await holdingWithAmount(admin, alice, 70.0)
  recordTimes.push(await settleUsdTransfer(admin, provider, alice, bob, aliceHolding2, 20.0, `traffic-${RUN_ID}-3`))
  log(`settled at ${recordTimes.join(', ')}`)

  // The app-side attribution of the same settlements. These reads consume no
  // synchronizer traffic, and they fail before the wait for the round.
  const activity = await attributedActivity(provider)
  assertEq('settlements confirmed by the app-provider', activity.settlements, 3)
  assertEq('settled volume confirmed by the app-provider', activity.settledVolume, 60)
  log(`app-side attribution: ${activity.settlements} settlements, ${activity.settledVolume} USD`)

  // Step 5: the network measures the traffic and computes a minting allowance for
  // the app-provider. The allowance comes from the batch that the SV confirms, so
  // it names the party that the round pays.
  const { round: settleRound, totals, allowance } = await waitForAttributedRound(roundBefore, provider)
  log(
    `round ${settleRound}: activity weight ${totals.total_app_activity_weight}, ` +
      `${totals.activity_records_count} activity records, ` +
      `${totals.rewarded_app_provider_parties_count} rewarded app-provider parties`,
  )
  log(`round ${settleRound} minting allowance of the app-provider: ${allowance} CC`)

  // Step 6: the SV mints the coupon of the app-provider for that round.
  const coupon = await waitForUnassignedCoupon(provider, settleRound)
  const couponAmount = Number(coupon.payload.amount)
  const couponRound = String(coupon.payload.round.number)
  log(`reward coupon for round ${couponRound}: ${couponAmount} CC`)
  assertEq('the coupon names the app-provider as its provider', coupon.payload.provider, provider)
  // The coupon on the ledger carries what Scan computed for the round, which ties
  // the measured traffic to the reward.
  assertEq(
    `the coupon carries the minting allowance of round ${settleRound}`,
    couponAmount,
    Number(allowance),
  )

  // Step 7: the app-provider divides the reward between its beneficiaries.
  const parties = { venue: provider, registrar, operator }
  const split = BENEFICIARY_SPLIT.map(([role, percentage]) => [parties[role], percentage, role])
  await assignBeneficiaries(provider, coupon.contractId, split.map(([party, percentage]) => [party, percentage]))
  log('assigned the beneficiaries of the coupon')

  const assigned = (await couponsOf(provider)).filter(
    (c) => c.payload.beneficiary && String(c.payload.round.number) === couponRound,
  )
  assertEq('one coupon for each beneficiary', assigned.length, split.length)
  const shares = []
  for (const [party, percentage, role] of split) {
    const hit = assigned.find((c) => c.payload.beneficiary === party)
    assertTrue(`a coupon for the ${role} beneficiary`, Boolean(hit))
    const amount = Number(hit.payload.amount)
    assertEq(`the ${role} share of ${couponAmount} CC`, amount, couponAmount * Number(percentage))
    shares.push({ role, party, percentage, amount })
    log(`${role}: ${amount} CC (${percentage} of the coupon)`)
  }
  assertEq('the shares add up to the coupon amount', shares.reduce((a, s) => a + s.amount, 0), couponAmount)

  if (EVIDENCE_FILE) {
    writeFileSync(
      EVIDENCE_FILE,
      `${JSON.stringify(
        {
          runId: RUN_ID,
          provider,
          settlements: activity.settlements,
          settledVolumeUsd: activity.settledVolume,
          settleRound,
          settleRecordTimes: recordTimes,
          totalAppActivityWeight: totals.total_app_activity_weight,
          activityRecordsCount: totals.activity_records_count,
          rewardedAppProviderPartiesCount: totals.rewarded_app_provider_parties_count,
          mintingAllowanceCc: allowance,
          couponRound,
          couponAmountCc: couponAmount,
          shares,
        },
        null,
        2,
      )}\n`,
    )
    log(`evidence written to ${EVIDENCE_FILE}`)
  }

  log('OK - CIP-0104 traffic-based app rewards reached the beneficiaries of the app-provider')
}

main().catch((err) => fail(err.stack ?? String(err)))
