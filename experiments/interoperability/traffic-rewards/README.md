# CIP-0104 traffic-based app rewards

[`harness.mjs`](harness.mjs) drives [CIP-0104](https://github.com/canton-foundation/cips/blob/main/cip-0104/cip-0104.md)
traffic-based app rewards end to end on [Canton LocalNet](https://docs.canton.network/sdks-tools/development-tools/localnet),
against the Amulet, Scan, and SV services that LocalNet runs.

CIP-0104 pays a featured app-provider for the sequencer and mediator traffic that
its transactions cause. The app writes no reward code: the sequencer measures the
traffic, Scan attributes it to the `FeaturedAppRight` holders of each
transaction, and the SV mints a `RewardCouponV2` for each rewarded provider when
a mining round closes. The harness therefore settles ordinary
[CIP-0112 settlement](../../settlement/cip-0112/) batches and then follows the
reward that the network computes from them.

## Reward path

1. The app-provider grants itself a `FeaturedAppRight`. LocalNet runs in DevNet
   mode, so the validator wallet API does this without an approval. Scan confirms
   the right. A fresh validator holds no synchronizer traffic and buys it from the
   SV on its own interval, so this first call waits for that traffic.
2. An SV vote sets `rewardConfig.mintingVersion` to
   `RewardVersion_TrafficBasedAppRewards` and lowers `appRewardCouponThreshold`
   far below its 0.5 USD default, because the reward of a run this small stays
   under that default and a round below the threshold mints no coupon. LocalNet
   has one SV and a voting threshold of 1, so the vote of the requester carries.
3. The app-provider settles three USD transfers as the settlement executor. These
   settlements are the traffic, and the harness records the ledger record time of
   each settle transaction. On the third batch a party that the settlement does
   not name as an executor submits first, and the participant rejects it. Only
   the named executor produces the traffic that the reward pays for.
4. The harness asserts the app-side attribution of those settlements from the
   `SettlementReceipt` views: the settlement count and the settled volume of the
   property that
   [`SettlementAttribution.daml`](../cip-exemplar/daml/OpenZeppelin/Experimental/Interop/SettlementAttribution.daml)
   specifies. The run has one executor and no second app-provider, so it counts
   no holdings-change event and does not exercise the negative case of a receipt
   that the app-provider only observes. The Daml walkthrough covers both.
5. Scan reports a round, at or after the round of the settlements, with a
   non-zero app activity weight whose confirmed batch of minting allowances names
   the app-provider party.
6. The app-provider holds a `RewardCouponV2` for that round, and the coupon
   carries the same amount as the minting allowance that Scan computed.
7. The app-provider assigns beneficiaries to the coupon
   (`RewardCoupon_AssignBeneficiaries`, 0.7 / 0.2 / 0.1). The choice replaces the
   coupon with one coupon for each beneficiary, and the harness asserts the three
   coupons and their amounts.

## Procedure

Start from the repository root. Make sure that DPM, Java 21+, Node.js 20+,
`curl`, Docker Compose v2, `git`, and `openssl` are installed. Then run:

```sh
scripts/localnet-cip0104-traffic-rewards.sh
```

The gate builds the interop exemplar DAR, founds a LocalNet, uploads the DAR over
the JSON Ledger API, runs the harness, and removes the network. The logs and the
JSON evidence of the run go to `.cache/cip0104-traffic-rewards/localnet/`.

A run takes about eight to ten minutes with the container images already pulled.
Most of that is waiting for the network: the validator buys traffic, a round
opens, the round closes, Scan computes its totals, and the SV confirms them.

The reward path needs the Amulet packages, Scan, and an SV, which a `dpm sandbox`
does not have, so LocalNet is the only backend. The shared
[`scripts/ledger.sh`](../../../scripts/ledger.sh) documents it, the Ledger API
authentication, and the environment overrides.

LocalNet publishes the SV app, Scan, and the wallet API behind one nginx that
routes on the `Host` header, so `wallet.localhost`, `sv.localhost`, and
`scan.localhost` must resolve to `127.0.0.1`. Most systems resolve every
`.localhost` name already. If yours does not, the harness stops with that
message, and you add the three names to `/etc/hosts` or point
`OZ_VALIDATOR_API_URL`, `OZ_SV_API_URL`, and `OZ_SCAN_API_URL` at names that
resolve.

A mining round takes two ticks, and the LocalNet tick is 10 minutes by default.
The gate founds its network with a 30s tick instead, so a round is about one
minute. The setting is an onboarding parameter, so it applies to a network that
the gate founds and not to one that already runs.

The gate reads the variables below.

| Variable | Purpose |
|---|---|
| `OZ_LOCALNET_TICK_DURATION` | Length of a tick, which is half a mining round |
| `OZ_REWARD_TIMEOUT_S` | Seconds to wait for the closed round and the coupon |
| `OZ_TRAFFIC_TIMEOUT_S` | Seconds to wait for validator traffic and for a round to open |
| `OZ_LEDGER_LOG_DIR` | Move the logs and the evidence of the run |
| `OZ_VALIDATOR_API_URL`, `OZ_SV_API_URL`, `OZ_SCAN_API_URL` | Splice service endpoints |
| `OZ_KEEP_LOCALNET` | Keep the network after the run |
| `OZ_USE_EXTERNAL_LEDGER` | Use a LocalNet that already runs, with the DAR uploaded. Point it at a disposable network: see the warning below |

The run changes the network, and nothing reverts those changes. It self-grants a
`FeaturedAppRight` to the app-provider. It votes the reward configuration to
traffic-based app rewards and lowers the coupon threshold. It grants `CanActAs`
for its parties to the Ledger API admin user. The gate founds and removes its own
LocalNet, so the changes go with that network. `OZ_USE_EXTERNAL_LEDGER=1` keeps
them, thus point that mode at a disposable network.

## Scope

The gate asserts the reward path up to the coupons of the beneficiaries.
Collection of a coupon into Canton Coin is validator-wallet automation on its own
schedule, which a run cannot predict: a node that shares rewards through its own
configuration waits most of the 36 hour coupon lifetime first. The gate therefore
makes no claim about minted Canton Coin.

The beneficiary percentages are an example of how an app divides its reward. The
reward amount is not: the network computes it from measured traffic and the
issuance curve of the round, and the harness asserts only that the shares match
the coupon that the network minted.

The gate does not isolate the share of the reward that the settlements earned. A
round pays for every transaction that it accounts to the app-provider, and on
LocalNet that includes the traffic top-ups of the app-provider's own validator,
which run on their own interval. With one featured app on the network the whole
app-reward pool of the round goes to that app in any case, so the amount reflects
the round rather than the three settlements.

Which round accounts for a given transaction is internal to Splice: several rounds
are open at once, the reward accounting fills behind them, and the CIP-0104
endpoints of Scan carry a "subject to change" note. The harness therefore searches
forward from the round it observed before settling, instead of computing the round
itself. A quiet round reports zero weight and no rewarded party, so the round it
finds did measure app traffic.

This experiment gives interoperability evidence on LocalNet. It is not a
production reward integration, and it does not make the app-provider a featured
app on TestNet or MainNet, where the Canton Foundation grants that status.
