# dtc-codes.json

Generic (SAE J2012-style) and Subaru manufacturer-specific trouble-code
descriptions, derived from [Wal33D/dtc-database](https://github.com/Wal33D/dtc-database)
(MIT License). Built from `data/source-data/{p,b,c,u}_codes.txt` +
`subaru_codes.txt`, parsed from `CODE - Description` lines into
`{"generic": {code: description}, "subaru": {code: description}}`.

9,415 generic + 93 Subaru-specific codes as of 2026-07-27. Spot-verified
against SAE definitions (P0420, P0128, U0100) before vendoring — an earlier
candidate dataset (mytrile/obd-trouble-codes) was rejected for systematic
code/description row drift.
