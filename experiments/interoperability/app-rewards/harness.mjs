#!/usr/bin/env node
// CIP-0104 rewards accounting walkthrough, fully off-chain. This Node client
// sends its commands to the CIP-0112 settlement surface through the JSON
// Ledger API v2. It gets the attribution of the app-provider and the example
// accrued rewards only from Ledger API reads. Real CIP-0104 reward
// infrastructure reads the ledger in the same way. The client does the same
// seven steps as the on-ledger executable specification
// (`Cip0104RewardsWalkthrough.daml`) and makes assertions on the same
// numbers. Thus the two artifacts show the same behavior.
//
// These operations use the ledger (all through `/v2/...` JSON Ledger API
// endpoints):
//   - party allocation                               (walkthrough setup)
//   - CreateCommand ToyHolding                       (the issuer mints)
//   - SettlementFactory_CreateAllocationInstruction + AllocationInstruction_Accept
//                                                    (each side authorizes its leg)
//   - SettlementFactory_SettleBatch                  (the app-provider executor settles;
//                                                     the factory is a disclosed contract)
//   - active-contracts reads of ToyHolding, SettlementReceipt,
//     SettlementEventLogEntry                        (the balances and the attribution surface)
//
// These operations do not use the ledger: all reward numbers. The functions
// `attributedActivity`, `accruedReward`, and `distributeReward` are plain
// JavaScript over query results. No reward-marker contract exists.
//
// The sandbox operates on WALLCLOCK time. The client settlements have no
// deadline. Thus this client does not need `setTime`. (The Daml walkthrough
// uses a deadline and static time.)
//
// Scope: experimental interoperability validation. The reward rate and the
// beneficiary split are examples. They are not the traffic-proportional CC
// calculation of CIP-0104 (that calculation is deferred to M2). This harness
// makes no CIP-0104 reward, SV, or Scan production claim.
//
// The script scripts/localnet-cip0104-rewards-walkthrough.sh starts this
// harness. The harness needs a local participant without authentication, with
// the exemplar DAR uploaded, and with the JSON Ledger API at OZ_JSON_API_URL
// (default http://127.0.0.1:7575).

const JSON_API = (process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:7575').replace(/\/+$/, '')

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

// The rejection that the engine raises when the settle actors are not the
// declared executors (Cip112.daml, eExecutorsMismatch).
const E_EXECUTORS_MISMATCH = 'Cip112Settlement: actors must equal settlement executors'

// --- off-ledger reward model (example values) --------------------------------

// The CC that accrues for each USD of settled volume that the app-provider
// confirmed. This value is not the CIP-0104 traffic-proportional rate.
const REWARD_RATE_PER_USD = 0.01

// The beneficiary split that the client applies when a round closes. The
// weights have a sum of 1.0.
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
    err.body = text
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

// Ledger-user setup on the sandbox without authentication: each submission
// must give a user id, also when authentication is off. Thus the harness
// creates one user with actAs rights for the walkthrough parties. On a real
// network, the validator operator does this setup through its IAM.
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

// Submit commands and collect the created contracts. Set `mustFail` to the
// exact rejection text that the engine must raise. A success, or a failure
// without that text (an HTTP 401/500, a network error, a different
// assertion), fails the walkthrough.
let cmdSeq = 0
async function submit(actAs, label, commands, { disclosedContracts, mustFail = null } = {}) {
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
    const body = err.body ?? String(err.message)
    if (!body.includes(mustFail)) throw err
    // Show only the error code, not the full HTTP body.
    const code = /"code":"([A-Z_]+)"/.exec(body)?.[1] ?? 'rejected'
    log(`${label}: rejected as expected (${code})`)
    return null
  }
}

const createdOf = (result, entity) => {
  const hit = result.created.find((c) => c.templateId?.includes(`:${entity}`))
  if (!hit) throw new Error(`no created ${entity}; created: ${result.created.map((c) => c.templateId).join(', ')}`)
  return hit.contractId
}

// Read the active contracts of one template, as `party` sees them. Set
// `withBlob` to also get the created-event blob. The blob lets the caller
// give the contract to an other party as a disclosed contract.
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

// --- settlement-surface helpers (the functions that an integrator calls) -----

const acct = (p) => ({ owner: p, provider: null, id: '' })
// Wallclock ledger: the walkthrough settlements have no deadline.
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

// Create the settlement factory. Then read it back with its created-event
// blob. The executor is not a stakeholder of the factory. Thus the client
// gives the factory to the executor as a disclosed contract. This is the JSON
// API equivalent of `discloseMany` in the Daml script.
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

// One side authorizes its leg: an allocation instruction through the factory,
// then an accept. The accept locks the input holdings.
async function createAndAcceptAllocation(admin, factory, settlement, authorizer, sides, inputHoldingCids) {
  // For a basic owner-only account, the account parties of the authorizer are
  // only the owner (Cip112 `accountParties`). The engine makes sure that the
  // actors are exactly equal to them.
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

async function settleBatch(executor, factory, settlement, legs, allocationCids, { mustFail = null } = {}) {
  return submit([executor], 'settle', [
    { ExerciseCommand: { templateId: T.factory, contractId: factory.factoryCid, choice: 'SettlementFactory_SettleBatch', choiceArgument: {
      settlement, transferLegs: legs, allocationCids, actors: [executor], d1ComplianceRef: null,
    } } },
  ], { disclosedContracts: [factory.disclosure], mustFail })
}

// A full transfer: a new factory, the two allocations, then the settle.
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
// The supply includes the locked holdings (the same as erc20TotalSupply). A
// pending allocation locks value. It does not burn value.
const totalSupply = (hs) =>
  hs.filter((h) => h.payload?.instrumentId?.id === 'USD').reduce((a, h) => a + Number(h.payload.amount), 0)

// The activity of the app-provider as the confirming executor. The data comes
// only from its Ledger API projection of the receipts and the holdings-change
// events, and only the settlements that the app-provider confirmed as
// executor count. Visibility alone does not attribute: the app-provider also
// observes receipts as an account party when it sends or receives in a
// settlement that an other party executes, and the function must not credit
// those. Each settled batch makes one receipt for each authorizer, and these
// receipts have the same settlement ref. Thus the function counts batches by
// unique ref. The sender side of each leg is in exactly one receipt. Thus the
// function adds the USD sender-side amounts to get the volume. An event
// counts only when one of its transfer legs is in a confirmed receipt.
async function attributedActivity(app) {
  const receipts = (await acs(app, T.receipt))
    .filter((r) => (r.payload.settlement.executors ?? []).includes(app))
  const events = await acs(app, T.eventLog)
  const refs = new Set(receipts.map((r) => r.payload.settlement.settlementRef.id))
  const confirmedLegIds = new Set(
    receipts.flatMap((r) => (r.payload.settledTransferLegSides ?? []).map((s) => s.transferLegId)),
  )
  const settledVolume = receipts
    .flatMap((r) => r.payload.settledTransferLegSides ?? [])
    .filter((s) => s.side === 'SenderSide' && s.instrumentId === 'USD')
    .reduce((a, s) => a + Number(s.amount), 0)
  const confirmedEvents = events
    .filter((e) => (e.payload.event?.transferLegSides ?? []).some((s) => confirmedLegIds.has(s.transferLegId)))
  return { settlements: refs.size, settledVolume, holdingsChangeEvents: confirmedEvents.length }
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

  // Step 0: the issuer mints 100 USD to alice. No settlement occurred. Thus
  // no activity is attributable.
  const aliceHolding = await mintUsd(admin, alice, 100.0)
  const a0 = await logSnapshot('step 0: minted, nothing settled', admin, app, alice, bob)
  assertEq('step 0 settlements', a0.settlements, 0)
  assertEq('step 0 volume', a0.settledVolume, 0)

  // Step 1: the app-provider executes a settlement that moves 30 USD from
  // alice to bob.
  await settleUsdTransfer(admin, app, alice, bob, aliceHolding, 30.0, 'reward-walk-1')
  const a1 = await logSnapshot('step 1: app settled alice -> bob 30 USD', admin, app, alice, bob)
  assertEq('step 1 settlements', a1.settlements, 1)
  assertEq('step 1 volume', a1.settledVolume, 30)
  assertEq('step 1 events', a1.holdingsChangeEvents, 2)
  assertEq('step 1 accrual', accruedReward(a1), 0.3)

  // Step 2: a second settlement (bob -> alice 10 USD) increases the counters.
  const bobHolding = await holdingWithAmount(admin, bob, 30.0)
  await settleUsdTransfer(admin, app, bob, alice, bobHolding, 10.0, 'reward-walk-2')
  const a2 = await logSnapshot('step 2: app settled bob -> alice 10 USD', admin, app, alice, bob)
  assertEq('step 2 settlements', a2.settlements, 2)
  assertEq('step 2 volume', a2.settledVolume, 40)
  assertEq('step 2 accrual', accruedReward(a2), 0.4)

  // Step 3: the client allocates a third batch. The allocation locks the 70
  // USD holding of alice. A party that is not the executor tries to settle
  // the batch. The attempt fails. The counters do not change: rewards accrue
  // only on activity that the app-provider confirmed.
  const factory = await mkFactory(admin)
  const settlement = settlementInfo('reward-walk-3', app)
  const leg = transferLeg('reward-walk-3', alice, bob, 20.0)
  const aliceInput = await holdingWithAmount(admin, alice, 70.0)
  const aliceAlloc = await createAndAcceptAllocation(admin, factory, settlement, alice, [legSide('SenderSide', leg)], [aliceInput])
  const bobAlloc = await createAndAcceptAllocation(admin, factory, settlement, bob, [legSide('ReceiverSide', leg)], [])
  await settleBatch(notApp, factory, settlement, [leg], [aliceAlloc, bobAlloc], { mustFail: E_EXECUTORS_MISMATCH })
  const a3 = await logSnapshot("step 3: non-executor settle failed (alice's 70 USD locked in the pending allocation)", admin, app, alice, bob)
  assertEq('step 3 settlements unchanged', a3.settlements, a2.settlements)
  assertEq('step 3 volume unchanged', a3.settledVolume, a2.settledVolume)

  // Step 4: the app-provider settles the pending batch. The counters
  // increase.
  await settleBatch(app, factory, settlement, [leg], [aliceAlloc, bobAlloc])
  const a4 = await logSnapshot('step 4: app settled the pending alice -> bob 20 USD batch', admin, app, alice, bob)
  assertEq('step 4 settlements', a4.settlements, 3)
  assertEq('step 4 volume', a4.settledVolume, 60)
  assertEq('step 4 events', a4.holdingsChangeEvents, 6)
  assertEq('step 4 accrual', accruedReward(a4), 0.6)

  // Step 5: an other executor (notApp) settles a transfer where the app is
  // only the receiver (bob -> app 5 USD). The app observes its own receipt
  // and holdings-change event as an account party. The attribution does not
  // credit them: only the settlements that the app confirmed as executor
  // count.
  const bobHolding2 = await holdingWithAmount(admin, bob, 20.0)
  await settleUsdTransfer(admin, notApp, bob, app, bobHolding2, 5.0, 'reward-walk-4')
  const rawReceipts = await acs(app, T.receipt)
  assertEq('step 5 receipts visible to the app', rawReceipts.length, 7)
  const a5 = await logSnapshot('step 5: notApp settled bob -> app 5 USD; app attribution unchanged', admin, app, alice, bob)
  assertEq('step 5 settlements unchanged', a5.settlements, a4.settlements)
  assertEq('step 5 volume unchanged', a5.settledVolume, a4.settledVolume)
  assertEq('step 5 events unchanged', a5.holdingsChangeEvents, a4.holdingsChangeEvents)

  // Step 6: the round closes. The client divides the accrued reward between
  // the declared beneficiaries. The sum of the shares is equal to the
  // accrual.
  const total = accruedReward(a4)
  const shares = distributeReward(total)
  log('== step 6: round closes, reward distributed (illustrative) ==')
  for (const [who, amt] of shares) log(`${who}: ${amt} CC`)
  assertEq('distribution conserves the accrual', shares.reduce((a, [, amt]) => a + amt, 0), total)
  assertEq('venue share', shares[0][1], 0.42)
  assertEq('registrar share', shares[1][1], 0.12)
  assertEq('operator share', shares[2][1], 0.06)

  // Final balance check: settlement kept the supply constant at each step.
  const holdings = await acs(admin, T.toyHolding)
  assertEq('final alice balance', balanceOf(holdings, alice), 60)
  assertEq('final bob balance', balanceOf(holdings, bob), 35)
  assertEq('final app balance', balanceOf(holdings, app), 5)
  assertEq('final supply', totalSupply(holdings), 100)

  log('OK - off-chain rewards walkthrough passed')
}

main().catch((err) => fail(err.stack ?? String(err)))
