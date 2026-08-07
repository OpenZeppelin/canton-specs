#!/usr/bin/env node
// CIP-0104 rewards-accounting walkthrough, fully off-chain: a Node client that
// drives the CIP-0112 settlement surface over the JSON Ledger API v2 and
// derives the app-provider's attribution and (illustrative) accrued rewards
// from Ledger API reads alone - the way real CIP-0104 reward infrastructure
// consumes the ledger. It replays the same six steps as the on-ledger
// executable spec (`Cip0104RewardsWalkthrough.daml`) and asserts the same
// numbers, so the two artifacts stay in lockstep.
//
// What talks to the ledger (all via `/v2/...` JSON Ledger API endpoints):
//   - party allocation (walkthrough plumbing)
//   - CreateCommand ToyHolding                       (issuer mints)
//   - SettlementFactory_CreateAllocationInstruction + AllocationInstruction_Accept
//                                                    (each side authorizes its leg)
//   - SettlementFactory_SettleBatch                  (app-provider executor settles;
//                                                     factory passed as a disclosed contract)
//   - active-contracts reads of ToyHolding, SettlementReceipt,
//     SettlementEventLogEntry                        (balances + the attribution surface)
//
// What never touches the ledger: every reward number. `attributedActivity`,
// `accruedReward`, and `distributeReward` are plain JavaScript over query
// results; no reward-marker contract exists to create.
//
// The sandbox runs on WALLCLOCK time: unlike the Daml walkthrough this client
// uses settlements without a deadline, so nothing needs `setTime`.
//
// Scope: experimental interoperability validation. The reward rate and the
// beneficiary split are illustrative stand-ins for CIP-0104's
// traffic-proportional CC math (precise calculation deferred to M2); this
// harness makes no CIP-0104 reward, SV, or Scan production claim.
//
// Orchestrated by scripts/localnet-cip0104-rewards-walkthrough.sh; needs an
// auth-less local participant with the exemplar DAR uploaded and the JSON
// Ledger API at OZ_JSON_API_URL (default http://127.0.0.1:7575).

const JSON_API = process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:7575'

const PKG_SETTLEMENT = '#openzeppelin-experimental-cip112-settlement'
const MOD_ENGINE = 'OpenZeppelin.Experimental.Settlement.Cip112'
const T = {
  factory: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementFactory`,
  toyHolding: `${PKG_SETTLEMENT}:${MOD_ENGINE}:ToyHolding`,
  receipt: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementReceipt`,
  eventLog: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementEventLogEntry`,
}

const FEATURE_FLAG = 'experimental.cip112-settlement.enabled'
const META = { entries: [] }
const EPS = 1e-9

// --- off-ledger reward model (illustrative) ----------------------------------

// CC accrued per USD of settled volume the app-provider confirmed; a stand-in
// for CIP-0104's traffic-proportional rate.
const REWARD_RATE_PER_USD = 0.01

// Beneficiary split applied when a round closes; weights sum to 1.0.
const BENEFICIARY_SPLIT = [
  ['venue (app-provider)', 0.7],
  ['instrument registrar', 0.2],
  ['validator operator', 0.1],
]

const accruedReward = (activity) => activity.settledVolume * REWARD_RATE_PER_USD
const distributeReward = (total) => BENEFICIARY_SPLIT.map(([who, w]) => [who, total * w])

// --- plumbing ----------------------------------------------------------------

const log = (...args) => console.log('[rewards-walkthrough]', ...args)

const fail = (msg) => {
  console.error('[rewards-walkthrough] FAIL:', msg)
  process.exit(1)
}

const assertEq = (label, actual, expected) => {
  const ok = typeof expected === 'number' ? Math.abs(actual - expected) < EPS : actual === expected
  if (!ok) fail(`${label}: expected ${expected}, saw ${actual}`)
}

async function api(method, path, body) {
  const res = await fetch(`${JSON_API}${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  if (!res.ok) {
    const err = new Error(`${method} ${path}: HTTP ${res.status}: ${text.slice(0, 500)}`)
    err.status = res.status
    throw err
  }
  return text ? JSON.parse(text) : undefined
}

async function allocateParty(hint) {
  const res = await api('POST', '/v2/parties', { partyIdHint: hint, identityProviderId: '' })
  const party = res?.partyDetails?.party ?? res?.party
  if (!party) throw new Error(`party allocation for ${hint} gave no party: ${JSON.stringify(res).slice(0, 300)}`)
  return party
}

// Ledger-user provisioning against the auth-less sandbox: submissions must
// name a user even when authentication is off, so the harness creates one with
// actAs rights over the walkthrough parties. On a real network the validator
// operator provisions this through its IAM instead.
const LEDGER_USER = 'oz-cip0104-walkthrough'
async function ensureLedgerUser(parties) {
  const rights = parties.map((party) => ({ kind: { CanActAs: { value: { party } } } }))
  try {
    await api('POST', '/v2/users', {
      user: { id: LEDGER_USER, primaryParty: '', isDeactivated: false, identityProviderId: '' },
      rights,
    })
    log(`provisioned ledger user ${LEDGER_USER}`)
  } catch (err) {
    if (err.status !== 409 && !String(err.message).includes('ALREADY_EXISTS')) throw err
    await api('POST', `/v2/users/${LEDGER_USER}/rights`, { userId: LEDGER_USER, rights, identityProviderId: '' })
    log(`ledger user ${LEDGER_USER} already existed; granted rights`)
  }
}

let cmdSeq = 0
async function submit(actAs, label, commands, { disclosedContracts, mustFail = false } = {}) {
  const commandId = `oz-cip0104-walkthrough-${label}-${++cmdSeq}`
  try {
    const res = await api('POST', '/v2/commands/submit-and-wait-for-transaction', {
      commands: { userId: LEDGER_USER, commands, commandId, actAs, ...(disclosedContracts ? { disclosedContracts } : {}) },
    })
    if (mustFail) fail(`${label}: expected the submission to fail, but it succeeded`)
    const created = []
    for (const e of res?.transaction?.events ?? []) {
      const ev = e?.CreatedEvent ?? e?.created ?? e?.CreatedTreeEvent?.value
      if (ev) created.push({ contractId: ev.contractId, templateId: ev.templateId, payload: ev.createArgument ?? ev.createArguments })
    }
    return { created, updateId: res?.transaction?.updateId }
  } catch (err) {
    if (!mustFail) throw err
    log(`${label}: rejected as expected (${String(err.message).slice(0, 120)}...)`)
    return null
  }
}

const createdOf = (result, entity) => {
  const hit = result.created.find((c) => c.templateId?.includes(`:${entity}`))
  if (!hit) throw new Error(`no created ${entity}; created: ${result.created.map((c) => c.templateId).join(', ')}`)
  return hit.contractId
}

// Active contracts of one template as seen by `party`; optionally carry the
// created-event blob so the contract can be passed on as a disclosed contract.
async function acs(party, templateId, { withBlob = false } = {}) {
  const end = await api('GET', '/v2/state/ledger-end')
  const request = {
    filter: {
      filtersByParty: {
        [party]: {
          cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId, includeCreatedEventBlob: withBlob } } } }],
        },
      },
    },
    verbose: false,
    activeAtOffset: end.offset,
  }
  const res = await api('POST', '/v2/state/active-contracts', request)
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
    throw new Error(`active-contracts: ${items.length} entries but none parseable; first: ${JSON.stringify(items[0]).slice(0, 400)}`)
  }
  return contracts
}

// --- settlement-surface helpers (the functions an integrator calls) ----------

const acct = (p) => ({ owner: p, provider: null, id: '' })
// Wallclock ledger: the walkthrough settlements carry no deadline.
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

// Create the settlement factory and read it back with its created-event blob,
// so the executor (a non-stakeholder) can be handed the factory as a disclosed
// contract - the JSON API equivalent of the Daml script's `discloseMany`.
async function mkFactory(admin) {
  const res = await submit([admin], 'factory', [
    { CreateCommand: { templateId: T.factory, createArguments: { admin, requiresComplianceAttestation: null, featureFlag: FEATURE_FLAG } } },
  ])
  const factoryCid = createdOf(res, 'SettlementFactory')
  const withBlob = (await acs(admin, T.factory, { withBlob: true })).find((c) => c.contractId === factoryCid)
  if (!withBlob?.createdEventBlob) throw new Error('factory created-event blob not found for disclosure')
  const disclosure = {
    templateId: withBlob.templateId,
    contractId: withBlob.contractId,
    createdEventBlob: withBlob.createdEventBlob,
    synchronizerId: withBlob.synchronizerId,
  }
  return { factoryCid, disclosure }
}

// One side authorizes its leg: allocation instruction via the factory, then
// accept (locking any input holdings).
async function createAndAcceptAllocation(admin, factory, settlement, authorizer, sides, inputHoldingCids) {
  // For a basic owner-only account the authorizer's account parties are just
  // the owner (Cip112 `accountParties`), and the engine asserts actors equal
  // them exactly.
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
    { ExerciseCommand: { templateId: `${PKG_SETTLEMENT}:${MOD_ENGINE}:AllocationInstruction`, contractId: instructionCid, choice: 'AllocationInstruction_Accept', choiceArgument: { actors } } },
  ])
  return createdOf(accepted, 'Allocation')
}

async function settleBatch(executor, factory, settlement, legs, allocationCids, { mustFail = false } = {}) {
  return submit([executor], 'settle', [
    { ExerciseCommand: { templateId: T.factory, contractId: factory.factoryCid, choice: 'SettlementFactory_SettleBatch', choiceArgument: {
      settlement, transferLegs: legs, allocationCids, actors: [executor], d1ComplianceRef: null,
    } } },
  ], { disclosedContracts: [factory.disclosure], mustFail })
}

// Full alice/bob-style transfer: fresh factory, both allocations, settle.
async function settleUsdTransfer(admin, app, sender, receiver, senderHoldingCid, amount, ref) {
  const factory = await mkFactory(admin)
  const settlement = settlementInfo(ref, app)
  const leg = transferLeg(ref, sender, receiver, amount)
  const senderAlloc = await createAndAcceptAllocation(admin, factory, settlement, sender, [legSide('SenderSide', leg)], [senderHoldingCid])
  const receiverAlloc = await createAndAcceptAllocation(admin, factory, settlement, receiver, [legSide('ReceiverSide', leg)], [])
  await settleBatch(app, factory, settlement, [leg], [senderAlloc, receiverAlloc])
}

// --- off-ledger reads: balances and the attribution surface ------------------

const unlockedUsd = (hs) => hs.filter((h) => !h.payload?.lock && h.payload?.instrumentId?.id === 'USD')
const balanceOf = (hs, party) =>
  unlockedUsd(hs).filter((h) => h.payload?.account?.owner === party).reduce((a, h) => a + Number(h.payload.amount), 0)
// Supply counts locked holdings too (mirrors erc20TotalSupply): a pending
// allocation locks value, it does not burn it.
const totalSupply = (hs) =>
  hs.filter((h) => h.payload?.instrumentId?.id === 'USD').reduce((a, h) => a + Number(h.payload.amount), 0)

// The app-provider's confirmed activity, derived entirely from its Ledger API
// projection of receipts and holdings-change events. Each settled batch yields
// one receipt per authorizer sharing a settlement ref (count by unique ref)
// and each leg's sender side appears in exactly one receipt (sum for volume).
async function attributedActivity(app) {
  const receipts = await acs(app, T.receipt)
  const events = await acs(app, T.eventLog)
  const refs = new Set(receipts.map((r) => r.payload.settlement.settlementRef.id))
  const settledVolume = receipts
    .flatMap((r) => r.payload.settledTransferLegSides ?? [])
    .filter((s) => s.side === 'SenderSide')
    .reduce((a, s) => a + Number(s.amount), 0)
  return { settlements: refs.size, settledVolume, holdingsChangeEvents: events.length }
}

async function logSnapshot(label, admin, app, alice, bob) {
  const holdings = await acs(admin, T.toyHolding)
  const activity = await attributedActivity(app)
  log(`== ${label} ==`)
  log(`balances (issuer view): alice=${balanceOf(holdings, alice)} USD, bob=${balanceOf(holdings, bob)} USD, totalSupply=${totalSupply(holdings)} USD`)
  log(`attribution (app view): settlements=${activity.settlements}, settledVolume=${activity.settledVolume} USD, holdingsChangeEvents=${activity.holdingsChangeEvents}`)
  log(`accrued reward (illustrative): ${accruedReward(activity)} CC`)
  return activity
}

async function holdingWithAmount(admin, owner, amount) {
  const holdings = await acs(admin, T.toyHolding)
  const hit = unlockedUsd(holdings).find((h) => h.payload.account.owner === owner && Math.abs(Number(h.payload.amount) - amount) < EPS)
  if (!hit) throw new Error(`no unlocked holding of ${amount} found for ${owner.slice(0, 24)}...`)
  return hit.contractId
}

// --- the walkthrough ----------------------------------------------------------

async function main() {
  log(`JSON Ledger API: ${JSON_API}`)
  const admin = await allocateParty('reward-walk-admin')
  const app = await allocateParty('reward-walk-app')
  const alice = await allocateParty('reward-walk-alice')
  const bob = await allocateParty('reward-walk-bob')
  const notApp = await allocateParty('reward-walk-notapp')
  await ensureLedgerUser([admin, app, alice, bob, notApp])

  // Step 0: the issuer mints 100 USD to alice; nothing is attributable yet.
  const aliceHolding = await mintUsd(admin, alice, 100.0)
  const a0 = await logSnapshot('step 0: minted, nothing settled', admin, app, alice, bob)
  assertEq('step 0 settlements', a0.settlements, 0)
  assertEq('step 0 volume', a0.settledVolume, 0)

  // Step 1: the app-provider executes a settlement moving 30 USD alice -> bob.
  await settleUsdTransfer(admin, app, alice, bob, aliceHolding, 30.0, 'reward-walk-1')
  const a1 = await logSnapshot('step 1: app settled alice -> bob 30 USD', admin, app, alice, bob)
  assertEq('step 1 settlements', a1.settlements, 1)
  assertEq('step 1 volume', a1.settledVolume, 30)
  assertEq('step 1 events', a1.holdingsChangeEvents, 2)
  assertEq('step 1 accrual', accruedReward(a1), 0.3)

  // Step 2: a second settlement (bob -> alice 10 USD) accumulates.
  const bobHolding = await holdingWithAmount(admin, bob, 30.0)
  await settleUsdTransfer(admin, app, bob, alice, bobHolding, 10.0, 'reward-walk-2')
  const a2 = await logSnapshot('step 2: app settled bob -> alice 10 USD', admin, app, alice, bob)
  assertEq('step 2 settlements', a2.settlements, 2)
  assertEq('step 2 volume', a2.settledVolume, 40)
  assertEq('step 2 accrual', accruedReward(a2), 0.4)

  // Step 3: a third batch is allocated (locking alice's 70 USD holding) and a
  // party that is not the executor tries to settle it. The attempt fails and
  // the counters do not move: rewards only accrue on confirmed executor
  // activity.
  const factory = await mkFactory(admin)
  const settlement = settlementInfo('reward-walk-3', app)
  const leg = transferLeg('reward-walk-3', alice, bob, 20.0)
  const aliceInput = await holdingWithAmount(admin, alice, 70.0)
  const aliceAlloc = await createAndAcceptAllocation(admin, factory, settlement, alice, [legSide('SenderSide', leg)], [aliceInput])
  const bobAlloc = await createAndAcceptAllocation(admin, factory, settlement, bob, [legSide('ReceiverSide', leg)], [])
  await settleBatch(notApp, factory, settlement, [leg], [aliceAlloc, bobAlloc], { mustFail: true })
  const a3 = await logSnapshot("step 3: non-executor settle failed (alice's 70 USD locked in the pending allocation)", admin, app, alice, bob)
  assertEq('step 3 settlements unchanged', a3.settlements, a2.settlements)
  assertEq('step 3 volume unchanged', a3.settledVolume, a2.settledVolume)

  // Step 4: the app-provider settles the pending batch; the counters increment.
  await settleBatch(app, factory, settlement, [leg], [aliceAlloc, bobAlloc])
  const a4 = await logSnapshot('step 4: app settled the pending alice -> bob 20 USD batch', admin, app, alice, bob)
  assertEq('step 4 settlements', a4.settlements, 3)
  assertEq('step 4 volume', a4.settledVolume, 60)
  assertEq('step 4 events', a4.holdingsChangeEvents, 6)
  assertEq('step 4 accrual', accruedReward(a4), 0.6)

  // Step 5: the round closes; the accrued reward is distributed across the
  // declared beneficiaries and the shares conserve the total.
  const total = accruedReward(a4)
  const shares = distributeReward(total)
  log('== step 5: round closes, reward distributed (illustrative) ==')
  for (const [who, amt] of shares) log(`${who}: ${amt} CC`)
  assertEq('distribution conserves the accrual', shares.reduce((a, [, amt]) => a + amt, 0), total)
  assertEq('venue share', shares[0][1], 0.42)
  assertEq('registrar share', shares[1][1], 0.12)
  assertEq('operator share', shares[2][1], 0.06)

  // Final balance check: settlement conserved supply throughout.
  const holdings = await acs(admin, T.toyHolding)
  assertEq('final alice balance', balanceOf(holdings, alice), 60)
  assertEq('final bob balance', balanceOf(holdings, bob), 40)
  assertEq('final supply', totalSupply(holdings), 100)

  log('OK - off-chain rewards walkthrough passed (numbers match Cip0104RewardsWalkthrough.daml)')
}

main().catch((err) => fail(err.stack ?? String(err)))
