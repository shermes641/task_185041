"""Acceptance checks for the Bergrivier 2026/27 non-energy charges (tariffs 5, 18, 19).

Expected values are read from docs/BERGRIVIER_2026_27_NERSA_RFD.md, so each value traces to the document.
The engine stores rates in CENTS (RfD rand values x 100). Rate classes are matched by what they
mean (unit, type), not by id: which class carries each charge is the implementer's decision.
Failing tests are the work to do; the guard tests must stay green.
"""
import pathlib
import re
from decimal import Decimal
from typing import Callable, NamedTuple

import pytest

import dbtools

RFD = pathlib.Path(__file__).resolve().parent.parent / "docs" / "BERGRIVIER_2026_27_NERSA_RFD.md"
START, END = "2026-07-01", "2027-06-30"   # RfD: effective 1 July 2026, one financial year
TARIFFS = (5, 18, 19)
BASELINE_MAX_RATE_ID = 446           # rows with a higher id were added by your seed


class Row(NamedTuple):
    rate_id: int
    rate: Decimal
    valid_from: str
    valid_to: str
    description: str
    rate_key: str
    cost_unit: str
    rate_type: str


def rfd_non_energy() -> dict[tuple[int, str], Decimal]:
    """{(engine_tariff, charge): rand_value} from the 'Non-energy charges' table."""
    out = {}
    section = RFD.read_text().split("## Non-energy charges")[1].split("\n## ")[0]
    for line in section.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 5 and cells[1].isdigit():
            out[(int(cells[1]), cells[2])] = Decimal(cells[3].replace(",", ""))
    return out


def cents(rand: Decimal) -> Decimal:
    return rand * 100


def rows(q, tariff: int) -> list[Row]:
    """Rates of one tariff, joined to their rate class."""
    return [Row(*r) for r in q(
        """SELECT r.rate_id, r.rate, r.valid_from::text, coalesce(r.valid_to::text, ''),
                  coalesce(r.description, ''), c.rate_key, c.cost_unit, coalesce(c.rate_type, '')
           FROM tariff_dev_v2.rates r JOIN tariff_dev_v2.rate_classes c USING (rate_class_id)
           WHERE r.tariff_id = %s ORDER BY r.rate_id""", (tariff,))]


def matching(q, tariff: int, value: Decimal, test: Callable[[Row], bool]) -> list[Row]:
    return [r for r in rows(q, tariff) if r.rate == value and test(r)]


# --- the document itself ------------------------------------------------------------------------------

def test_rfd_table_parses():
    d = rfd_non_energy()
    assert d[(18, "Basic")] == Decimal("3592.40")
    assert d[(5, "Demand")] == Decimal("4.09")
    assert len(d) == 10


# --- guards: existing 2026/27 rows must not change ---------------------------------------------------

def test_energy_rates_still_there(q):
    for t in TARIFFS:
        tou = [r for r in rows(q, t) if r.rate_type == "tou"]
        assert len(tou) == 6, f"tariff {t} lost or gained TOU energy rows"
        assert all(r.valid_from == START and r.valid_to == END for r in tou)


def test_bulk_demand_rates_unchanged(q):
    d = rfd_non_energy()
    assert matching(q, 18, cents(d[(18, "Demand")]), lambda r: r.rate_type == "demand")
    assert matching(q, 19, cents(d[(19, "Network demand")]), lambda r: r.rate_type == "demand")


def test_no_other_tariff_changed(q):
    """The cut-down DB holds only tariffs 5, 18, 19 (plus shared reference data)."""
    assert {r[0] for r in q("SELECT DISTINCT tariff_id FROM tariff_dev_v2.rates")} <= set(TARIFFS)


# --- the work -----------------------------------------------------------------------------------------

@pytest.mark.parametrize("tariff", TARIFFS)
def test_basic_charge_per_month(q, tariff):
    """Basic charge is per POS per month: a monthly fixed charge, not per amp, not per day."""
    value = cents(rfd_non_energy()[(tariff, "Basic")])
    found = matching(q, tariff, value, lambda r: r.rate_type == "fixed" and r.cost_unit == "month")
    assert found, f"tariff {tariff}: no monthly fixed rate of {value} c (RfD R{value / 100})"


@pytest.mark.parametrize("tariff", (18, 19))
def test_reactive_energy_per_kvarh(q, tariff):
    value = cents(rfd_non_energy()[(tariff, "Reactive energy")])
    found = matching(q, tariff, value, lambda r: r.cost_unit == "kVArh")
    assert found, f"tariff {tariff}: no kVArh rate of {value} c (RfD R0.3110/kVArh)"


def test_tariff5_demand_is_per_amp_per_phase(q):
    """R4.09 per Amp per phase per month is NOT a kVA demand charge."""
    value = cents(rfd_non_energy()[(5, "Demand")])
    assert matching(q, 5, value, lambda r: "amp" in r.cost_unit.lower()), \
        "tariff 5: the 409 c demand rate needs a rate class whose cost_unit says Amp (not kVA)"
    assert not matching(q, 5, value, lambda r: r.cost_unit == "kVA"), "tariff 5 still prices 4.09 as R/kVA"


def test_new_rows_use_rfd_dates_and_cite_source(q):
    """Rows your seed adds start 2026-07-01 (not 2026-04-01), end 2027-06-30, and say where the value is from."""
    new = [(t, r) for t in TARIFFS for r in rows(q, t) if r.rate_id > BASELINE_MAX_RATE_ID]
    assert new, "your seed has added no rates yet"
    for t, r in new:
        assert r.valid_from == START and r.valid_to == END, f"tariff {t} {r.rate_key}: window {r.valid_from}..{r.valid_to}"
        assert re.search(r"RfD|NERSA", r.description), f"tariff {t} {r.rate_key}: description must cite the RfD / NERSA letter"


def test_every_rate_class_is_linked_to_its_tariff(q):
    """A rate row is unusable unless tariff_rate_classes covers its window."""
    missing = q(
        """SELECT DISTINCT r.tariff_id, r.rate_class_id FROM tariff_dev_v2.rates r
           WHERE r.tariff_id = ANY(%s) AND NOT EXISTS (
             SELECT 1 FROM tariff_dev_v2.tariff_rate_classes l
             WHERE l.tariff_id = r.tariff_id AND l.rate_class_id = r.rate_class_id
               AND l.valid_from <= r.valid_from AND (l.valid_to IS NULL OR l.valid_to >= r.valid_to))""",
        (list(TARIFFS),))
    assert not missing, f"rate classes without a covering tariff_rate_classes row: {missing}"


def test_seeds_are_idempotent(q):
    """Applying the seed files a second time changes nothing."""
    snap = ("SELECT (SELECT count(*) FROM tariff_dev_v2.rates), (SELECT coalesce(sum(rate), 0) FROM tariff_dev_v2.rates),"
            " (SELECT count(*) FROM tariff_dev_v2.rate_classes), (SELECT count(*) FROM tariff_dev_v2.tariff_rate_classes)")
    before = q(snap)
    dbtools.apply_seeds()
    assert q(snap) == before
