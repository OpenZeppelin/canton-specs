#!/usr/bin/env node
// CIP-0104 app-reward attribution of the bridge on Canton LocalNet.
//
// The question: when `ba` and `br` each hold a `FeaturedAppRight`, which of
// them does the network pay for an inbound credit, and in what proportion?
// CIP-0104 pays the confirmers of a view, which are the signatories of a create
// node and the input contract signatories and actors of an exercise node. `br`
// is the actor of every gateway choice, so it should earn from the gateway
// transactions it submits. This harness measures that.
//
// Two phases, which `scripts/localnet-bridge-app-rewards.sh` runs around the
// Daml Script that produces the credits:
//
//   prepare   vote traffic-based app rewards on, allocate the bridge parties,
//             feature `ba`, `br`, and the wTOK admin, wait for rounds that
//             opened after the rights existed, and write the parties for the
//             Daml Script.
//   measure   search the rounds from the start of the run forward and report
//             the minting allowance of each featured party per round.
//
// The wTOK admin is featured too, so that the nested registry nodes of the
// gateway transaction (the mint, the factory call, the offer) show up as its
// share. No other party on the network is featured, so the app-reward pool of a
// round splits among these three alone, and their allowances compare directly.
//
// LocalNet runs in DevNet mode, so any party features itself with
// `AmuletRules_DevNet_FeatureApp`. The AmuletRules contract comes from Scan,
// with its created-event blob, and goes into the exercise as a disclosed
// contract.
//
// Environment:
//   OZ_JSON_API_URL            JSON Ledger API of the app-provider participant
//   OZ_LEDGER_TOKEN_FILE       file with the token of the participant admin user
//   OZ_LEDGER_USER_ID          Ledger API user that the harness submits as
//   OZ_SV_API_URL              SV app API
//   OZ_SCAN_API_URL            Scan API
//   OZ_LOCALNET_AUTH_SECRET    HS256 secret that the Splice apps accept
//   OZ_LOCALNET_AUTH_AUDIENCE  audience that the Splice apps accept
//   OZ_SV_USER                 wallet admin user of the SV
//   OZ_STATE_FILE              file that `prepare` writes and `measure` reads
//   OZ_PARTIES_FILE            input file of the Daml Script (the parties)
//   OZ_EVIDENCE_FILE           JSON evidence that `measure` writes
//   OZ_REWARD_TIMEOUT_S        seconds to wait for the rewarded rounds
//   OZ_TRAFFIC_TIMEOUT_S       seconds to wait for validator traffic

import { readFileSync, writeFileSync } from 'node:fs'
import { createHmac } from 'node:crypto'

const trimSlash = (url) => url.replace(/\/+$/, '')

const JSON_API = trimSlash(process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:3975')
const SV_API = trimSlash(process.env.OZ_SV_API_URL ?? 'http://sv.localhost:4000/api/sv')
const SCAN_API = trimSlash(process.env.OZ_SCAN_API_URL ?? 'http://scan.localhost:4000/api/scan')
const AUTH_SECRET = process.env.OZ_LOCALNET_AUTH_SECRET ?? 'unsafe'
const AUTH_AUDIENCE = process.env.OZ_LOCALNET_AUTH_AUDIENCE ?? 'https://canton.network.global'
const SV_USER = process.env.OZ_SV_USER ?? 'sv'
const LEDGER_USER = process.env.OZ_LEDGER_USER_ID ?? 'ledger-api-user'
const STATE_FILE = process.env.OZ_STATE_FILE ?? 'app-rewards-state.json'
const PARTIES_FILE = process.env.OZ_PARTIES_FILE ?? 'app-rewards-parties.json'
const EVIDENCE_FILE = process.env.OZ_EVIDENCE_FILE ?? null
const REWARD_TIMEOUT_MS = Number(process.env.OZ_REWARD_TIMEOUT_S ?? 900) * 1000
const TRAFFIC_TIMEOUT_MS = Number(process.env.OZ_TRAFFIC_TIMEOUT_S ?? 300) * 1000
const POLL_INTERVAL_MS = 5000

const LEDGER_TOKEN = process.env.OZ_LEDGER_TOKEN_FILE
  ? readFileSync(process.env.OZ_LEDGER_TOKEN_FILE, 'utf8').trim()
  : null

const AMULET_RULES = '#splice-amulet:Splice.AmuletRules:AmuletRules'
const REWARD_COUPON_V2 = '#splice-amulet:Splice.Amulet:RewardCouponV2'

// The parties of the Daml Script record `BridgeParties`, in its field names.
const ROLES = ['ba', 'br', 'pa', 'wtokAdmin', 'recipient', 'holder', 'attester1', 'attester2', 'attester3']
const FEATURED = ['ba', 'br', 'wtokAdmin']

const log = (...args) => console.log('[bridge-rewards]', ...args)
const fail = (msg) => {
  console.error('[bridge-rewards] FAIL:', msg)
  process.exit(1)
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function http(method, url, { token = null, body = undefined, label = url } = {}) {
  const res = await fetch(url, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  if (!res.ok) {
    const err = new Error(`${method} ${label}: HTTP ${res.status}: ${text.slice(0, 600)}`)
    err.status = res.status
    err.body = text
    throw err
  }
  return text ? JSON.parse(text) : undefined
}

function spliceToken(subject) {
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url')
  const header = b64({ alg: 'HS256', typ: 'JWT' })
  const payload = b64({ sub: subject, aud: AUTH_AUDIENCE })
  const signature = createHmac('sha256', AUTH_SECRET).update(`${header}.${payload}`).digest('base64url')
  return `${header}.${payload}.${signature}`
}

const svApi = (method, path, body) => http(method, `${SV_API}${path}`, { token: spliceToken(SV_USER), body, label: `sv ${path}` })
const scanApi = (method, path) => http(method, `${SCAN_API}${path}`, { label: `scan ${path}` })
const ledgerApi = (method, path, body) => http(method, `${JSON_API}${path}`, { token: LEDGER_TOKEN, body, label: `ledger ${path}` })

async function waitFor(label, probe, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  let attempts = 0
  for (;;) {
    const result = await probe()
    if (result !== null && result !== undefined) return result
    attempts += 1
    if (Date.now() >= deadline) fail(`${label}: no result after ${Math.round(timeoutMs / 1000)}s`)
    if (attempts % 6 === 0) log(`still waiting for ${label} (${attempts * (POLL_INTERVAL_MS / 1000)}s)`)
    await sleep(POLL_INTERVAL_MS)
  }
}

async function requireResolvableHosts() {
  const { lookup } = await import('node:dns/promises')
  for (const url of [SV_API, SCAN_API]) {
    const { hostname } = new URL(url)
    try {
      await lookup(hostname)
    } catch (err) {
      fail(`${hostname} does not resolve (${err.code}). Add "127.0.0.1 ${hostname}" to /etc/hosts.`)
    }
  }
}

// --- Ledger API --------------------------------------------------------------

async function allocateParty(hint) {
  const res = await ledgerApi('POST', '/v2/parties', { partyIdHint: hint, identityProviderId: '' })
  const party = res?.partyDetails?.party ?? res?.party
  if (!party) throw new Error(`party allocation for ${hint} gave no party`)
  return party
}

async function grantActAs(parties) {
  const rights = parties.map((party) => ({ kind: { CanActAs: { value: { party } } } }))
  await ledgerApi('POST', `/v2/users/${LEDGER_USER}/rights`, { userId: LEDGER_USER, rights, identityProviderId: '' })
}

let cmdSeq = 0
const submit = (actAs, label, commands, disclosedContracts = []) =>
  ledgerApi('POST', '/v2/commands/submit-and-wait-for-transaction', {
    commands: { userId: LEDGER_USER, commands, commandId: `oz-bridge-rewards-${label}-${++cmdSeq}`, actAs, disclosedContracts },
  })

async function acs(party, templateId) {
  const end = await ledgerApi('GET', '/v2/state/ledger-end')
  const res = await ledgerApi('POST', '/v2/state/active-contracts', {
    filter: { filtersByParty: { [party]: { cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId, includeCreatedEventBlob: false } } } }] } } },
    verbose: false,
    activeAtOffset: end.offset,
  })
  const items = Array.isArray(res) ? res : []
  return items
    .map((item) => item?.contractEntry?.JsActiveContract?.createdEvent)
    .filter(Boolean)
    .map((ev) => ({ contractId: ev.contractId, payload: ev.createArgument }))
}

// --- Splice ------------------------------------------------------------------

const trafficRewardConfig = () => ({
  mintingVersion: 'RewardVersion_TrafficBasedAppRewards',
  dryRunVersion: null,
  batchSize: '100',
  rewardCouponTimeToLive: { microseconds: String(36 * 3600 * 1000000) },
  // Far below the 0.5 USD default: a round below the threshold mints nothing,
  // and the traffic of two credits is small.
  appRewardCouponThreshold: '0.0000000001',
})

async function enableTrafficBasedRewards() {
  const dso = await scanApi('GET', '/v0/dso')
  const base = dso.amulet_rules.contract.payload.configSchedule.initialValue
  if (base.rewardConfig?.mintingVersion === 'RewardVersion_TrafficBasedAppRewards') {
    log('the network already runs traffic-based app rewards')
    return
  }
  if (Number(dso.voting_threshold) !== 1) fail(`the SV voting threshold is ${dso.voting_threshold}, not 1`)
  const newConfig = { ...structuredClone(base), rewardConfig: trafficRewardConfig() }
  await svApi('POST', '/v0/admin/sv/voterequest/create', {
    requester: dso.sv_party_id,
    action: { tag: 'ARC_AmuletRules', value: { amuletRulesAction: { tag: 'CRARC_SetConfig', value: { newConfig, baseConfig: base } } } },
    url: 'https://github.com/OpenZeppelin/canton-specs',
    description: 'enable CIP-0104 traffic-based app rewards for the bridge attribution check',
    expiration: { microseconds: String(24 * 3600 * 1000000) },
  })
  await waitFor('the traffic-based reward configuration', async () => {
    const current = await scanApi('GET', '/v0/dso')
    const cfg = current.amulet_rules.contract.payload.configSchedule.initialValue.rewardConfig
    return cfg?.mintingVersion === 'RewardVersion_TrafficBasedAppRewards' ? cfg : null
  }, REWARD_TIMEOUT_MS)
  log('the network runs traffic-based app rewards')
}

const latestRound = async () => Number((await scanApi('GET', '/v0/dso')).latest_mining_round.contract.payload.round.number)

// Feature `party` with the DevNet choice. A fresh validator buys its first
// synchronizer traffic on its own interval, so the first submission that costs
// traffic may be refused until then; the loop retries.
async function featureParty(role, party) {
  const dso = await scanApi('GET', '/v0/dso')
  const rules = dso.amulet_rules.contract
  const disclosure = {
    templateId: rules.template_id,
    contractId: rules.contract_id,
    createdEventBlob: rules.created_event_blob,
    synchronizerId: dso.amulet_rules.domain_id ?? '',
  }
  await waitFor(`synchronizer traffic to feature ${role}`, async () => {
    try {
      return await submit([party], `feature-${role}`, [
        { ExerciseCommand: { templateId: AMULET_RULES, contractId: rules.contract_id, choice: 'AmuletRules_DevNet_FeatureApp', choiceArgument: { provider: party, activityWeight: null } } },
      ], [disclosure])
    } catch (err) {
      const body = err.body ?? String(err.message)
      if (/TRAFFIC|traffic|SEQUENCER_REQUEST_FAILED|UNAVAILABLE/.test(body)) return null
      throw err
    }
  }, TRAFFIC_TIMEOUT_MS)
  const featured = await scanApi('GET', '/v0/featured-apps')
  const mine = (featured.featured_apps ?? []).filter((a) => a.payload?.provider === party)
  if (mine.length !== 1) fail(`Scan reports ${mine.length} featured app rights for ${role}, expected 1`)
  log(`featured ${role} (${party.slice(0, 24)}...)`)
}

async function roundMintingAllowances(round) {
  const hash = await scanApi('GET', `/v0/internal/reward-accounting-process/rounds/${round}/root-hash`)
  if (hash.status !== 'Ok') return null
  const batch = await scanApi('GET', `/v0/internal/reward-accounting-process/rounds/${round}/batches/${hash.root_hash}`)
  return batch.minting_allowances ?? []
}

// --- phases ------------------------------------------------------------------

const RUN_ID = Date.now().toString(36)

async function prepare() {
  if (!LEDGER_TOKEN) fail('OZ_LEDGER_TOKEN_FILE is required')
  await requireResolvableHosts()
  await enableTrafficBasedRewards()

  const parties = {}
  for (const role of ROLES) parties[role] = await allocateParty(`bridge-${role}-${RUN_ID}`)
  await grantActAs(Object.values(parties))
  log(`allocated ${ROLES.length} parties (run ${RUN_ID})`)

  for (const role of FEATURED) await featureParty(role, parties[role])
  const featuredAt = await latestRound()

  // A right pays only for rounds whose start it precedes, and Splice keeps
  // three rounds open at once. Waiting three rounds past the featuring puts the
  // credits into rounds that opened with the rights active.
  await waitFor(`round ${featuredAt + 3} to open`, async () => {
    const latest = await latestRound()
    return latest >= featuredAt + 3 ? latest : null
  }, REWARD_TIMEOUT_MS)
  const roundBefore = await latestRound()
  log(`featured at round ${featuredAt}; the credits start at round ${roundBefore}`)

  writeFileSync(PARTIES_FILE, `${JSON.stringify(parties, null, 2)}\n`)
  writeFileSync(STATE_FILE, `${JSON.stringify({ runId: RUN_ID, parties, featuredAt, roundBefore }, null, 2)}\n`)
  log(`wrote ${PARTIES_FILE} and ${STATE_FILE}`)
}

const readState = () => JSON.parse(readFileSync(STATE_FILE, 'utf8'))
const writeState = (state) => writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`)

// Record the latest open round under `name`, so that the report can place the
// setup and the credits.
async function mark(name) {
  const state = readState()
  state.marks = { ...(state.marks ?? {}), [name]: await latestRound() }
  writeState(state)
  log(`${name}: latest open round ${state.marks[name]}`)
}

// Wait until `n` rounds have opened since the last mark. Splice attributes a
// transaction to a round about two behind the latest open one, so two rounds
// put the next transactions into a later round than the ones before the mark.
async function waitRounds(n) {
  const state = readState()
  const marks = Object.values(state.marks ?? {})
  const from = marks.length > 0 ? Math.max(...marks) : await latestRound()
  await waitFor(`round ${from + n} to open`, async () => {
    const latest = await latestRound()
    return latest >= from + n ? latest : null
  }, REWARD_TIMEOUT_MS)
}

async function measure() {
  const state = readState()
  const { parties, featuredAt } = state
  const byParty = Object.fromEntries(FEATURED.map((role) => [role, parties[role]]))
  const roleOf = (party) => FEATURED.find((role) => byParty[role] === party) ?? 'other'

  // Walk the rounds forward from the featuring. Stop after a rewarded round is
  // followed by a round that Scan has closed and that pays none of the three
  // parties, or when the timeout runs out with at least one rewarded round in
  // hand.
  const rounds = []
  let next = featuredAt
  const deadline = Date.now() + REWARD_TIMEOUT_MS
  for (;;) {
    const latest = await latestRound()
    while (next < latest) {
      const totals = await scanApi('GET', `/v0/internal/reward-accounting-process/rounds/${next}/activity-totals`)
      if (totals.status !== 'Ok') {
        // A round that Scan has not closed yet: wait for it. A round that stays
        // undetermined three rounds later never closes with totals (Scan began
        // its accounting after it), so the walk moves on.
        if (next >= latest - 3) break
        rounds.push({ round: next, status: totals.status, allowances: [] })
        log(`round ${next}: ${totals.status}`)
        next += 1
        continue
      }
      const allowances = (await roundMintingAllowances(next)) ?? []
      const entry = {
        round: next,
        totalAppActivityWeight: totals.total_app_activity_weight,
        activityRecordsCount: totals.activity_records_count,
        rewardedParties: totals.rewarded_app_provider_parties_count,
        allowances: allowances.map((a) => ({ role: roleOf(a.provider), provider: a.provider, amount: a.amount })),
      }
      rounds.push(entry)
      const paid = entry.allowances.map((a) => `${a.role}=${a.amount}`).join(', ') || 'nobody'
      log(`round ${next}: weight ${entry.totalAppActivityWeight}, ${entry.activityRecordsCount} records, paid ${paid}`)
      next += 1
    }
    // The credits were sent when `creditAt` was the latest open round, so their
    // round is at or below it. A quiet closed round at or past that number
    // means the credit round has been passed.
    const rewarded = rounds.filter((r) => r.allowances.length > 0)
    const last = rounds[rounds.length - 1]
    const creditAt = state.marks?.creditAt ?? state.roundBefore
    if (rewarded.length > 0 && last && last.status === undefined && last.allowances.length === 0 && last.round >= creditAt) break
    if (Date.now() >= deadline) {
      if (rewarded.length === 0) fail('no round paid any of the featured parties')
      log('timeout reached with rewarded rounds in hand')
      break
    }
    await sleep(POLL_INTERVAL_MS)
  }

  for (const [name, round] of Object.entries(state.marks ?? {})) log(`${name}: latest open round ${round} at the time`)
  const totals = Object.fromEntries(FEATURED.map((role) => [role, 0]))
  for (const r of rounds) for (const a of r.allowances) if (a.role in totals) totals[a.role] += Number(a.amount)
  const sum = Object.values(totals).reduce((a, b) => a + b, 0)
  log('--- minting allowances over all rewarded rounds (setup and credits) ---')
  for (const role of FEATURED) {
    const share = sum > 0 ? ((100 * totals[role]) / sum).toFixed(1) : '0.0'
    log(`${role.padEnd(10)} ${totals[role].toFixed(10)} CC  (${share}%)`)
  }

  // The coupons that the SV minted for each party, if any are already there.
  const coupons = {}
  for (const role of FEATURED) {
    try {
      coupons[role] = (await acs(parties[role], REWARD_COUPON_V2))
        .filter((c) => c.payload.provider === parties[role])
        .map((c) => ({ round: c.payload.round.number, amount: c.payload.amount }))
    } catch (err) {
      coupons[role] = { error: String(err.message) }
    }
    log(`${role} coupons: ${JSON.stringify(coupons[role])}`)
  }

  if (EVIDENCE_FILE) {
    writeFileSync(EVIDENCE_FILE, `${JSON.stringify({ ...state, rounds, totals, coupons }, null, 2)}\n`)
    log(`evidence written to ${EVIDENCE_FILE}`)
  }
}

const [phase, arg] = process.argv.slice(2)
const phases = {
  prepare,
  measure,
  mark: () => mark(arg ?? fail('mark needs a name')),
  wait: () => waitRounds(Number(arg ?? 2)),
}
const run = phases[phase]
if (!run) fail('usage: app-rewards-harness.mjs prepare | mark <name> | wait <rounds> | measure')
run().catch((err) => fail(err.stack ?? String(err)))
