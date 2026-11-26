# Bergrivier 2026/27: NERSA Decision and Reasons for Decision (RfD)

Source: <https://www.nersa.org.za/files/files/2026/07/BergrivierMunicipality_ReasonsforDecisionontariffapplicationprocessforFY2026-27FY.pdf>
(26 pages, text PDF). REC meeting 6 May 2026; tariffs effective 1 July 2026.
Section 7 "Tariff Analysis" is the authoritative table. This file transcribes the values the
engine is concerned with and records what they mean for the schema. It supersedes the OCR of the
scanned approval letter and the earlier `BERGRIVIER_2026_27_STATUS.md` working note (no longer in the repo).

Decision: average increase 8.00% (domestic, small, bulk and TOU tariffs); SSEG 0.00%;
streetlights 0.00%; availability 11.63%. NERSA also requires a report accounting for all costs
in the COS study by **31 January 2027**.

Schema conventions: `season_id` 1 = High (Jun-Aug), 2 = Low (Sep-May);
`period_id` 1 = Peak, 2 = Standard, 3 = Off Peak. Energy in c/kWh.

## Engine tariffs (TOU)

| RfD # | Engine tariff | Season | Peak | Standard | Off-peak |
|---|---|---|---:|---:|---:|
| 8 Bulk TOU MV 11 kV | 18 | High | 255.42 | **239.84** | 221.10 |
| 8 Bulk TOU MV 11 kV | 18 | Low | 255.42 | **236.09** | 221.10 |
| 9 Bulk TOU LV >50 kVA | 19 | High | 255.42 | **239.84** | 221.10 |
| 9 Bulk TOU LV >50 kVA | 19 | Low | 255.42 | **236.09** | 221.10 |
| 10 Small consumer TOU <=50 kVA | 5 | High | 774.00 | 267.94 | 207.63 |
| 10 Small consumer TOU <=50 kVA | 5 | Low | 379.28 | 256.70 | 207.63 |
| 11 SSEG feed-in credit | 20 | High | (522.29) | (145.66) | (103.83) |
| 11 SSEG feed-in credit | 20 | Low | (228.52) | (137.30) | (103.83) |

Standard is higher in High season than Low on both bulk tariffs. An earlier OCR reading had
these swapped; do not reintroduce it. SSEG credits are negative as printed, unchanged from 2025/26.

## Non-energy charges

| RfD # | Engine tariff | Charge | Value | Unit as printed in RfD |
|---|---|---|---:|---|
| 8 | 18 | Basic | 3,592.40 | R/month per meter |
| 8 | 18 | Network access | 30.31 | R/kVA/month |
| 8 | 18 | Demand | 322.64 | R/kVA/month |
| 8 | 18 | Reactive energy | 0.3110 | R/kVArh |
| 9 | 19 | Basic | 3,033.53 | R/month/POS |
| 9 | 19 | Network access | 30.31 | R/kVA/month |
| 9 | 19 | Network demand | 344.76 | R/kVA |
| 9 | 19 | Reactive energy | 0.3110 | R/kVArh |
| 10 | 5 | Basic | 297.58 | R/month/POS |
| 10 | 5 | Demand | 4.09 | **R/Amp/phase/month** |

Unit consequences:

- Basic charges are per POS (point of supply) per month, **not per Amp**. No amps attribute is
  needed for them. The earlier status doc labelled them R/Amp/month.
- Tariff 5's 4.09 is per Amp per phase per month, not R/kVA. The local `demand_rates` row
  (stored 409 c, `monthly_peak`) and its bill label "R/kVA" are therefore wrong in unit, and
  billing it needs amps and phases attributes.
- Network access (18, 19) is new in 2026/27 and reactive energy is new (2025/26: none).

## Other tariffs in the RfD (not in the engine)

Percentages are all +8.00% on 2025/26 unless stated. Rand/kWh values are printed as c/kWh.

| RfD # | Tariff | 2026/27 |
|---|---|---|
| 1 | Domestic indigent prepaid (20 A) | blocks 0-50 220.29, 51-250 262.26, 251-600 280.60, >600 458.95 c/kWh |
| 2 | Domestic lifeline prepaid (20 A) | blocks 262.26 / 262.26 / 280.60 / 458.95 c/kWh; basic R82.08/month |
| 3 | Small 1-phase conventional | blocks 220.29 / 280.67 / 324.37 / 358.66 c/kWh; basic R465.91/month |
| 4 | Small 1-phase prepaid | blocks 220.29 / 283.26 / 390.76 / 458.95 c/kWh; basic R82.08/month |
| 5 | Small 3-phase conventional | basic R1,662.87/month; energy 355.24 c/kWh |
| 6 | Small 3-phase prepaid | basic R82.08/month; energy 393.36 (printed R/kWh, c/kWh by magnitude) |
| 7 | Small 3-phase munic | basic R1,662.87/month; energy 193.51 c/kWh |
| 12 | Streetlights (0%) | R80.91/luminaire/month; 368.47 c/kWh |
| 13 | Availability (+11.63%) | R297.71/stand/month |

Block bands in the RfD are 0-50, 51-250, 251-600 and >600 kWh (the municipality's March
application used different bands).

## Revenue and loss figures (context only)

Approved average increase 8.00%; NERSA cost tool indicated 11.63%. Allowable revenue
R255,561,776 (2026/27) against R228,013,665 (2025/26). Allowed losses 9.50%. Bulk purchases
R206,108,551, based on the 9.01% ERTSA increase.
