CREATE EXTENSION IF NOT EXISTS btree_gist;
-- Shared enum the dump's functions reference (values read from the function body)
CREATE SCHEMA IF NOT EXISTS shared_types;
CREATE TYPE shared_types.power_direction_type AS ENUM ('above', 'below', 'both');

--
-- PostgreSQL database dump
--


-- Dumped from database version 18.7 (Ubuntu 18.7-1.pgdg22.04+5)
-- Dumped by pg_dump version 18.6 (Homebrew)

-- Started on 2026-11-26 08:41:28 EST

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 46 (class 2615 OID 180041834)
-- Name: tariff_dev_v2; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA tariff_dev_v2;


--
-- TOC entry 11997 (class 0 OID 0)
-- Dependencies: 46
-- Name: SCHEMA tariff_dev_v2; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA tariff_dev_v2 IS 'Tariff engine v2. Built by build.sql, filled by load_from_tariff_dev.sql. tariff_dev stays the source of truth until cutover.';


--
-- TOC entry 3519 (class 1255 OID 180043253)
-- Name: assert_collections_consistent(integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.assert_collections_consistent(p_collection_ids integer[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_problem TEXT;
BEGIN
    SELECT string_agg(format('collection %s: array %s, rows %s', c.attribute_collection_id,
                             c.attribute_value_ids, coalesce(r.ids, '{}')), '; ' ORDER BY c.attribute_collection_id)
    INTO v_problem
    FROM tariff_dev_v2.attribute_collections c
    LEFT JOIN LATERAL (
        SELECT array_agg(acv.attribute_value_id ORDER BY acv.attribute_value_id) AS ids
        FROM tariff_dev_v2.attribute_collection_values acv
        WHERE acv.attribute_collection_id = c.attribute_collection_id
    ) r ON true
    WHERE c.attribute_collection_id = ANY (p_collection_ids)
      AND c.attribute_value_ids IS DISTINCT FROM coalesce(r.ids, '{}');

    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'attribute_value_ids and attribute_collection_values disagree: %', v_problem
            USING HINT = 'Insert the collection and its value rows together, with the same value ids.';
    END IF;
END
$$;


--
-- TOC entry 3467 (class 1255 OID 180043254)
-- Name: assert_rates_match_attributes(integer[], integer[], bigint[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.assert_rates_match_attributes(p_rate_class_ids integer[], p_collection_ids integer[], p_rate_ids bigint[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_problem TEXT;
    v_count   INT;
BEGIN
    WITH checked AS (
        SELECT r.rate_id, r.rate_class_id, r.attribute_collection_id,
               (SELECT coalesce(array_agg(a.attribute_code ORDER BY a.attribute_code), '{}')
                FROM tariff_dev_v2.rate_class_attributes rca
                JOIN tariff_dev_v2.attributes a USING (attribute_id)
                WHERE rca.rate_class_id = r.rate_class_id) AS required,
               (SELECT coalesce(array_agg(a.attribute_code ORDER BY a.attribute_code), '{}')
                FROM tariff_dev_v2.attribute_collection_values acv
                JOIN tariff_dev_v2.attributes a USING (attribute_id)
                WHERE acv.attribute_collection_id = r.attribute_collection_id) AS present
        FROM tariff_dev_v2.rates r
        WHERE r.rate_class_id = ANY (p_rate_class_ids)
           OR r.attribute_collection_id = ANY (p_collection_ids)
           OR r.rate_id = ANY (p_rate_ids)
    ),
    bad AS (
        SELECT * FROM checked WHERE required IS DISTINCT FROM present
    )
    SELECT (SELECT count(*) FROM bad),
           string_agg(format('rate %s (rate class %s, collection %s): rate class requires %s, collection has %s',
                             rate_id, rate_class_id, attribute_collection_id, required, present), '; ' ORDER BY rate_id)
    INTO v_count, v_problem
    FROM (SELECT * FROM bad ORDER BY rate_id LIMIT 20) b;

    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION '% rate(s) whose attribute collection does not match their rate class (up to 20 listed): %', v_count, v_problem
            USING HINT = 'Each rate needs a collection with one value for exactly the attributes in rate_class_attributes for its rate class (none = collection 0).';
    END IF;
END
$$;


--
-- TOC entry 2672 (class 1255 OID 180043612)
-- Name: assert_rates_within_windows(integer[], integer[], bigint[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.assert_rates_within_windows(p_tariff_ids integer[], p_rate_class_ids integer[], p_rate_ids bigint[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_problem TEXT;
    v_count   INT;
BEGIN
    WITH checked AS (
        SELECT r.rate_id, r.tariff_id, r.rate_class_id, r.valid_from, r.valid_to,
               (SELECT range_agg(daterange(w.valid_from, w.valid_to, '[]'))
                FROM tariff_dev_v2.tariff_rate_classes w
                WHERE w.tariff_id = r.tariff_id AND w.rate_class_id = r.rate_class_id) AS windows
        FROM tariff_dev_v2.rates r
        WHERE r.rate_id = ANY (p_rate_ids)
           OR (r.tariff_id, r.rate_class_id) IN (SELECT * FROM unnest(p_tariff_ids, p_rate_class_ids))
    ),
    bad AS (
        SELECT * FROM checked
        WHERE windows IS NULL OR NOT windows @> daterange(valid_from, valid_to, '[]')
    )
    SELECT (SELECT count(*) FROM bad),
           string_agg(format('rate %s (tariff %s, rate class %s, %s .. %s): windows %s', rate_id, tariff_id, rate_class_id,
                             valid_from, coalesce(valid_to::TEXT, 'open'), coalesce(windows::TEXT, 'none')), '; ' ORDER BY rate_id)
    INTO v_count, v_problem
    FROM (SELECT * FROM bad ORDER BY rate_id LIMIT 20) b;

    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION '% rate(s) outside their tariff''s tariff_rate_classes windows (up to 20 listed): %', v_count, v_problem
            USING HINT = 'Add or widen the tariff_rate_classes window for the tariff and rate class in the same transaction.';
    END IF;
END
$$;


--
-- TOC entry 2903 (class 1255 OID 181700690)
-- Name: attribute_collection_id(integer, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.attribute_collection_id(p_rate_class_id integer, p_attribute_value_ids integer[]) RETURNS integer
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_ids      INT[] := tariff_dev_v2.sorted_distinct_ids(coalesce(p_attribute_value_ids, '{}'));
    v_problem  TEXT;
    v_id       INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tariff_dev_v2.rate_classes WHERE rate_class_id = p_rate_class_id) THEN
        RAISE EXCEPTION 'rate class % does not exist', p_rate_class_id;
    END IF;

    WITH given AS (
        SELECT x.id, av.attribute_id
        FROM unnest(v_ids) AS x(id)
        LEFT JOIN tariff_dev_v2.attribute_values av ON av.attribute_value_id = x.id
    ),
    required AS (
        SELECT rca.attribute_id, a.attribute_code
        FROM tariff_dev_v2.rate_class_attributes rca
        JOIN tariff_dev_v2.attributes a USING (attribute_id)
        WHERE rca.rate_class_id = p_rate_class_id
    )
    SELECT string_agg(msg, '; ' ORDER BY msg) INTO v_problem
    FROM (
        SELECT format('%s is not an attribute value id', g.id) AS msg
        FROM given g WHERE g.attribute_id IS NULL
        UNION ALL
        SELECT format('value %s is for attribute %s, which rate class %s does not use',
                      g.id, (SELECT attribute_code FROM tariff_dev_v2.attributes WHERE attribute_id = g.attribute_id),
                      p_rate_class_id)
        FROM given g
        WHERE g.attribute_id IS NOT NULL
          AND g.attribute_id NOT IN (SELECT attribute_id FROM required)
        UNION ALL
        SELECT format('more than one value for %s', r.attribute_code)
        FROM required r JOIN given g USING (attribute_id)
        GROUP BY r.attribute_code HAVING count(*) > 1
        UNION ALL
        SELECT format('no value for %s', r.attribute_code)
        FROM required r
        WHERE r.attribute_id NOT IN (SELECT attribute_id FROM given WHERE attribute_id IS NOT NULL)
    ) p;

    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'rate class %, attribute values %: %', p_rate_class_id, v_ids, v_problem;
    END IF;

    IF v_ids = '{}' THEN
        RETURN 0;
    END IF;

    SELECT c.attribute_collection_id INTO v_id
    FROM tariff_dev_v2.attribute_collections c
    WHERE c.attribute_value_ids = v_ids
      AND EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
                  WHERE r.rate_class_id = p_rate_class_id
                    AND r.attribute_collection_id = c.attribute_collection_id);

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'rate class %: no rates exist for attribute values %', p_rate_class_id, v_ids;
    END IF;
    RETURN v_id;
END
$$;


--
-- TOC entry 11998 (class 0 OID 0)
-- Dependencies: 2903
-- Name: FUNCTION attribute_collection_id(p_rate_class_id integer, p_attribute_value_ids integer[]); Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON FUNCTION tariff_dev_v2.attribute_collection_id(p_rate_class_id integer, p_attribute_value_ids integer[]) IS 'Collection id for a rate class and the selected attribute_value_ids (0 = no attributes). Raises on an invalid selection.';


--
-- TOC entry 3192 (class 1255 OID 181700691)
-- Name: attribute_value_ids_for(integer, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.attribute_value_ids_for(p_rate_class_id integer, p_attribute_value_ids integer[]) RETURNS integer[]
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(array_agg(DISTINCT x.id ORDER BY x.id), '{}')
    FROM unnest(coalesce(p_attribute_value_ids, '{}')) AS x(id)
    JOIN tariff_dev_v2.attribute_values av ON av.attribute_value_id = x.id
    JOIN tariff_dev_v2.rate_class_attributes rca
      ON rca.attribute_id = av.attribute_id AND rca.rate_class_id = p_rate_class_id;
$$;


--
-- TOC entry 11999 (class 0 OID 0)
-- Dependencies: 3192
-- Name: FUNCTION attribute_value_ids_for(p_rate_class_id integer, p_attribute_value_ids integer[]); Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON FUNCTION tariff_dev_v2.attribute_value_ids_for(p_rate_class_id integer, p_attribute_value_ids integer[]) IS 'The selected attribute_value_ids that a rate class uses (a subset; unknown or unused ids are dropped).';


--
-- TOC entry 2344 (class 1255 OID 181700721)
-- Name: capacity_rate_cost(integer, integer, integer[], numeric, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.capacity_rate_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_capacity numeric, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    WITH segments AS (
        SELECT r.rate,
               GREATEST(r.valid_from, lnk.valid_from, tariff_dev_v2.local_date(p_start_date))                    AS segment_start,
               LEAST(COALESCE(r.valid_to, 'infinity'::DATE),
                     COALESCE(lnk.valid_to, 'infinity'::DATE), tariff_dev_v2.local_date(p_end_date))             AS segment_end
        FROM tariff_dev_v2.tariff_tou_pattern_link lnk
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
        WHERE lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND r.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
          AND lnk.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(lnk.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
    ),
    with_days AS (
        SELECT s.*, (s.segment_end - s.segment_start + 1) AS days_at_rate,
               SUM(s.segment_end - s.segment_start + 1) OVER () AS total_days
        FROM segments s
        WHERE s.segment_end >= s.segment_start
    )
    SELECT COALESCE(SUM(ROUND(p_capacity * w.rate / 100.0 * w.days_at_rate / w.total_days, 2)), 0)
    FROM with_days w;
$$;


--
-- TOC entry 2806 (class 1255 OID 181700701)
-- Name: exceedance_months(numeric[], numeric); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.exceedance_months(p_max numeric[], p_limit numeric) RETURNS TABLE(k integer, max_value numeric, is_event boolean, in_deadband boolean, free boolean)
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    n      INT := coalesce(array_length(p_max, 1), 0);
    v_free BOOLEAN[] := array_fill(FALSE, ARRAY[greatest(n, 1)]);
    i      INT;
    v_db   BOOLEAN;
BEGIN
    FOR i IN REVERSE n .. 1 LOOP            -- oldest (largest k) first
        v_db := p_max[i] > p_limit AND p_max[i] <= 1.05 * p_limit;
        v_free[i] := coalesce(v_db, FALSE)
                     AND (SELECT count(*) FROM generate_series(i + 1, least(i + 11, n)) g(j) WHERE v_free[g.j]) < 2;
    END LOOP;
    RETURN QUERY
    SELECT g.idx - 1, p_max[g.idx], coalesce(p_max[g.idx] > p_limit, FALSE),
           coalesce(p_max[g.idx] > p_limit AND p_max[g.idx] <= 1.05 * p_limit, FALSE), v_free[g.idx]
    FROM generate_series(1, least(n, 12)) g(idx)
    WHERE p_max[g.idx] IS NOT NULL;
END
$$;


--
-- TOC entry 2313 (class 1255 OID 181700698)
-- Name: get_block_energy_cost_from_std_val_hourly(text, integer, integer, text, integer, timestamp without time zone, timestamp without time zone, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_block_energy_cost_from_std_val_hourly(p_system_cuid text, p_tariff_id integer, p_rate_class_id integer, p_std_val_column text, p_dwelling_units integer, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_attribute_value_ids integer[]) RETURNS TABLE("timestamp" integer, cost double precision, energy double precision, rate double precision, block_from double precision)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_coll INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids);
    v_bad  TEXT;
    v_day_rates TEXT;
BEGIN
    IF p_dwelling_units IS NULL OR p_dwelling_units < 1 THEN
        RAISE EXCEPTION 'tariff %, rate class %: dwelling units must be at least 1 (got %)', p_tariff_id, p_rate_class_id, p_dwelling_units;
    END IF;
    IF (SELECT rc.rate_type FROM tariff_dev_v2.rate_classes rc WHERE rc.rate_class_id = p_rate_class_id) IS DISTINCT FROM 'block' THEN
        RAISE EXCEPTION 'rate class % is not a block class', p_rate_class_id;
    END IF;

    -- each day of the interval with its block rates: the day's season / period from the pattern link
    v_day_rates := format($dr$
        SELECT g.d::DATE AS day, concat_ws('/', r.valid_from, r.season_id, r.period_id) AS era,
               r.block_from, r.rate
        FROM generate_series(tariff_dev_v2.local_date(%1$L::TIMESTAMP), tariff_dev_v2.local_date(%2$L::TIMESTAMP), INTERVAL '1 day') g(d)
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id = %3$s AND lnk.rate_class_id = %4$s
          AND g.d::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        JOIN (SELECT DISTINCT pattern_detail_id, month, season_id, period_id FROM tariff_dev_v2.tou_pattern_detail) pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM g.d)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id = lnk.tariff_id AND r.rate_class_id = lnk.rate_class_id
          AND r.pattern_class_id = lnk.pattern_class_id AND r.attribute_collection_id = %5$s
          AND r.season_id = pd.season_id AND r.period_id = pd.period_id
          AND g.d::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    $dr$, p_start_date, p_end_date, p_tariff_id, p_rate_class_id, v_coll);

    -- each day: one set of blocks (one season / period, one era), starting at 0
    EXECUTE format($chk$
        SELECT string_agg(day::TEXT, ', ' ORDER BY day)
        FROM (SELECT day FROM (%s) d GROUP BY day
              HAVING count(DISTINCT era) > 1 OR min(block_from) <> 0 OR count(*) <> count(DISTINCT block_from)) x
    $chk$, v_day_rates) INTO v_bad;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'tariff %, rate class %: the blocks of % are not one set starting at 0', p_tariff_id, p_rate_class_id, v_bad;
    END IF;

    RETURN QUERY EXECUTE format($sql$
        WITH day_rates AS (%2$s),
        eras AS (
            SELECT d.era, count(DISTINCT d.day) AS n_days, max(d.day) AS last_day
            FROM day_rates d GROUP BY d.era
        ),
        hours AS (
            SELECT (sv."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' - INTERVAL '1 hour')::DATE AS day,
                   sv.%1$I AS kwh
            FROM hyper."SystemStandardValueLog" sv
            WHERE sv.system_cuid = $1
              AND sv."timestamp" BETWEEN $2 AND $3
              AND sv.%1$I IS NOT NULL
        ),
        era_kwh AS (
            SELECT d.era, sum(h.kwh)::NUMERIC AS kwh
            FROM hours h JOIN (SELECT DISTINCT day, era FROM day_rates) d ON d.day = h.day
            GROUP BY d.era
        ),
        blocks AS (
            SELECT DISTINCT d.era, d.block_from, d.rate FROM day_rates d
        ),
        priced AS (
            SELECT e.era, e.last_day, b.block_from, b.rate,
                   GREATEST(0, LEAST(k.kwh, COALESCE(LEAD(b.block_from) OVER w * f.f, k.kwh)) - b.block_from * f.f) AS q
            FROM eras e
            JOIN era_kwh k ON k.era = e.era
            JOIN blocks b ON b.era = e.era
            CROSS JOIN LATERAL (SELECT $4::NUMERIC * e.n_days / 30.4375 AS f) f
            WINDOW w AS (PARTITION BY e.era ORDER BY b.block_from)
        )
        SELECT EXTRACT(EPOCH FROM p.last_day)::INT,
               ROUND(p.q * p.rate / 100.0, 2)::FLOAT,
               ROUND(p.q, 3)::FLOAT,
               ROUND(p.rate / 100.0, 4)::FLOAT,
               p.block_from::FLOAT
        FROM priced p
        WHERE p.q > 0 OR p.block_from = 0
        ORDER BY p.last_day, p.block_from
    $sql$, p_std_val_column, v_day_rates)
    USING p_system_cuid, p_start_date, p_end_date, p_dwelling_units;
END
$_$;


--
-- TOC entry 3991 (class 1255 OID 181700710)
-- Name: get_block_rates_for_interval(integer, integer, integer[], timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_block_rates_for_interval(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, rate double precision, block_from double precision, season text)
    LANGUAGE sql STABLE
    AS $$
    WITH day_rates AS (
        SELECT g.d::DATE AS day, r.valid_from, r.season_id, r.period_id, r.block_from, r.rate
        FROM generate_series(tariff_dev_v2.local_date(p_start_date), tariff_dev_v2.local_date(p_end_date), INTERVAL '1 day') g(d)
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id = p_tariff_id AND lnk.rate_class_id = p_rate_class_id
          AND g.d::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        JOIN (SELECT DISTINCT pattern_detail_id, month, season_id, period_id FROM tariff_dev_v2.tou_pattern_detail) pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM g.d)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id = lnk.tariff_id AND r.rate_class_id = lnk.rate_class_id
          AND r.pattern_class_id = lnk.pattern_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
          AND r.season_id = pd.season_id AND r.period_id = pd.period_id
          AND g.d::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    )
    SELECT EXTRACT(EPOCH FROM max(d.day))::INT,
           ROUND((d.rate / 100.0)::NUMERIC, 4)::FLOAT,
           d.block_from::FLOAT,
           COALESCE(rcs.season_label, s.season_name)::TEXT
    FROM day_rates d
    JOIN tariff_dev_v2.tou_seasons s ON s.season_id = d.season_id
    LEFT JOIN tariff_dev_v2.rate_class_tou_seasons rcs ON rcs.rate_class_id = p_rate_class_id AND rcs.season_id = d.season_id
    GROUP BY d.valid_from, d.season_id, d.period_id, d.block_from, d.rate, rcs.season_label, s.season_name
    ORDER BY max(d.day), d.block_from;
$$;


--
-- TOC entry 3666 (class 1255 OID 181700703)
-- Name: get_capacity_charge_cost_from_auc(integer, integer, integer[], integer, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_capacity_charge_cost_from_auc(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_notified_demand integer, p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, auc double precision, rate double precision, subsys text)
    LANGUAGE sql STABLE
    AS $$
    WITH months AS (        -- tariff_dev_v2.nmd_months: k = 0 is the billing month
        SELECT * FROM tariff_dev_v2.nmd_months(p_subsystem_cuid, p_notified_demand, p_start_date, p_end_date)
    ),
    auc AS (                -- utilised capacity: NMD, the billing month's MD, non-exempt events of the 12 months
        SELECT GREATEST(p_notified_demand,
                        COALESCE((SELECT m.max_demand FROM months m WHERE m.k = 0), 0),
                        COALESCE((SELECT max(m.max_demand) FROM months m WHERE m.is_event AND NOT m.deadband_exempt), 0)) AS value
    ),
    segments AS (
        SELECT r.rate,
               GREATEST(r.valid_from, lnk.valid_from, tariff_dev_v2.local_date(p_start_date))                    AS segment_start,
               LEAST(COALESCE(r.valid_to, 'infinity'::DATE),
                     COALESCE(lnk.valid_to, 'infinity'::DATE), tariff_dev_v2.local_date(p_end_date))             AS segment_end
        FROM tariff_dev_v2.tariff_tou_pattern_link lnk
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
        WHERE lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND r.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
          AND lnk.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(lnk.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
    ),
    with_days AS (
        SELECT s.*, (s.segment_end - s.segment_start + 1) AS days_at_rate,
               SUM(s.segment_end - s.segment_start + 1) OVER () AS total_days
        FROM segments s
        WHERE s.segment_end >= s.segment_start
    )
    SELECT EXTRACT(EPOCH FROM w.segment_end)::INT AS "timestamp",
           ROUND((a.value * w.rate / 100.0 * w.days_at_rate / w.total_days)::NUMERIC, 2)::FLOAT AS cost,
           ROUND(a.value::NUMERIC, 2)::FLOAT AS auc,
           ROUND((w.rate / 100.0)::NUMERIC, 4)::FLOAT AS rate,
           p_subsystem_cuid AS subsys
    FROM with_days w
    CROSS JOIN auc a
    ORDER BY w.segment_start;
$$;


--
-- TOC entry 3239 (class 1255 OID 181700700)
-- Name: get_daily_charge_cost(integer, integer, integer[], timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_daily_charge_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, rate double precision)
    LANGUAGE sql STABLE
    AS $$
    SELECT EXTRACT(EPOCH FROM d.day)::INT                                AS "timestamp",
           ROUND((r.rate / 100.0)::NUMERIC, 2)::FLOAT      AS cost,
           ROUND((r.rate / 100.0)::NUMERIC, 4)::FLOAT                     AS rate
    FROM generate_series(tariff_dev_v2.local_date(p_start_date), tariff_dev_v2.local_date(p_end_date), INTERVAL '1 day') AS d(day)
    JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
      ON  lnk.tariff_id     = p_tariff_id
      AND lnk.rate_class_id = p_rate_class_id
      AND d.day::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
    JOIN tariff_dev_v2.rates r
      ON  r.tariff_id               = lnk.tariff_id
      AND r.rate_class_id           = lnk.rate_class_id
      AND r.pattern_class_id        = lnk.pattern_class_id
      AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
      AND d.day::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    ORDER BY d.day;
$$;


--
-- TOC entry 2418 (class 1255 OID 181700708)
-- Name: get_demand_charge_cost_city_power(integer, integer, integer[], text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_demand_charge_cost_city_power(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, demand double precision, rate double precision, demand_at integer, subsys text)
    LANGUAGE sql STABLE
    AS $$
    WITH months AS (
        SELECT m.k,
               tariff_dev_v2.local_months_before(p_start_date, m.k)                                AS m_start,
               tariff_dev_v2.local_months_before(p_start_date, m.k - 1) - INTERVAL '1 millisecond' AS m_end
        FROM generate_series(1, 12) m(k)
    ),
    md AS (
        SELECT m.k, max(elem.value::NUMERIC) AS md
        FROM months m
        JOIN hyper."SystemStandardValueLog" sv
          ON  sv.subsystem_cuid = p_subsystem_cuid
          AND sv."timestamp" BETWEEN m.m_start AND m.m_end
          AND jsonb_typeof(sv.extensions -> 'binned_30_kva') = 'array'
        CROSS JOIN LATERAL jsonb_array_elements_text(sv.extensions -> 'binned_30_kva') AS elem(value)
        GROUP BY m.k
    ),
    rolling AS (
        SELECT 0.8 * avg(md) AS kva
        FROM (SELECT md FROM md WHERE md IS NOT NULL ORDER BY md DESC LIMIT 3) top3
    )
    SELECT f.*
    FROM tariff_dev_v2.get_demand_charge_cost_from_binned_kva(
             p_tariff_id, p_rate_class_id, p_attribute_value_ids, p_subsystem_cuid, p_start_date, p_end_date,
             GREATEST(
                 (SELECT r.rate FROM tariff_dev_v2.rates r JOIN tariff_dev_v2.rate_classes rc USING (rate_class_id)
                  WHERE r.tariff_id = p_tariff_id AND rc.rate_key = 'minimum_demand_kva'
                    AND tariff_dev_v2.local_date(p_end_date) BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
                  ORDER BY r.valid_from DESC LIMIT 1),
                 (SELECT kva FROM rolling))) f;
$$;


--
-- TOC entry 3443 (class 1255 OID 181700705)
-- Name: get_demand_charge_cost_from_binned_kva(integer, integer, integer[], text, timestamp without time zone, timestamp without time zone, numeric); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_demand_charge_cost_from_binned_kva(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_minimum_demand numeric DEFAULT NULL::numeric) RETURNS TABLE("timestamp" integer, cost double precision, demand double precision, rate double precision, demand_at integer, subsys text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_coll      INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids);
    v_demand    NUMERIC;
    v_demand_at TIMESTAMP;
    v_bad       TEXT;
BEGIN
    -- chargeable demand: the highest 30-minute kVA in an hour that has a rate
    SELECT h.kva, h.raw_ts INTO v_demand, v_demand_at
    FROM (
        SELECT sv."timestamp" AS raw_ts,
               (sv."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' - INTERVAL '1 hour') AS ts,
               (SELECT max(e.value::NUMERIC) FROM jsonb_array_elements_text(sv.extensions -> 'binned_30_kva') e(value)) AS kva
        FROM hyper."SystemStandardValueLog" sv
        WHERE sv.subsystem_cuid = p_subsystem_cuid
          AND sv."timestamp" BETWEEN p_start_date AND p_end_date
          AND jsonb_typeof(sv.extensions -> 'binned_30_kva') = 'array'
    ) h
    JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
      ON  lnk.tariff_id     = p_tariff_id
      AND lnk.rate_class_id = p_rate_class_id
      AND h.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
    LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
      ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
      AND hol.holiday_date      = h.ts::DATE
    JOIN tariff_dev_v2.tou_pattern_detail pd
      ON  pd.pattern_detail_id = lnk.pattern_detail_id
      AND pd.month = EXTRACT(MONTH FROM h.ts)::INT
      AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM h.ts)::INT)
      AND pd.hour  = EXTRACT(HOUR  FROM h.ts)::INT
    WHERE h.kva IS NOT NULL
      AND EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
                  WHERE r.tariff_id = lnk.tariff_id AND r.rate_class_id = lnk.rate_class_id
                    AND r.pattern_class_id = lnk.pattern_class_id AND r.attribute_collection_id = v_coll
                    AND r.season_id = pd.season_id AND r.period_id = pd.period_id
                    AND h.ts::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE))
    ORDER BY h.kva DESC, h.raw_ts
    LIMIT 1;

    IF v_demand IS NULL THEN
        RETURN;
    END IF;
    v_demand := GREATEST(v_demand, COALESCE(p_minimum_demand, 0));   -- a tariff's minimum demand charged

    -- the rates of one day's chargeable periods must agree (one rate per month)
    WITH day_rates AS (    -- the season's chargeable rates per day (rates differ only by date and season)
        SELECT d.day, min(r.rate) AS rate, count(DISTINCT r.rate) AS n
        FROM generate_series(tariff_dev_v2.local_date(p_start_date), tariff_dev_v2.local_date(p_end_date), INTERVAL '1 day') AS g(d)
        CROSS JOIN LATERAL (SELECT g.d::DATE AS day) d
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND d.day BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        JOIN (SELECT DISTINCT pattern_detail_id, month, season_id FROM tariff_dev_v2.tou_pattern_detail) pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM d.day)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id = lnk.tariff_id AND r.rate_class_id = lnk.rate_class_id
          AND r.pattern_class_id = lnk.pattern_class_id AND r.attribute_collection_id = v_coll
          AND r.season_id = pd.season_id
          AND d.day BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
        GROUP BY d.day
    )
    SELECT string_agg(day::TEXT, ', ' ORDER BY day) INTO v_bad FROM day_rates WHERE n > 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'tariff %, rate class %: the chargeable periods have different rates on %', p_tariff_id, p_rate_class_id, v_bad;
    END IF;

    -- runs of days at one rate -> prorated segments
    RETURN QUERY
    WITH day_rates AS (    -- the season's chargeable rates per day (rates differ only by date and season)
        SELECT d.day, min(r.rate) AS rate, count(DISTINCT r.rate) AS n
        FROM generate_series(tariff_dev_v2.local_date(p_start_date), tariff_dev_v2.local_date(p_end_date), INTERVAL '1 day') AS g(d)
        CROSS JOIN LATERAL (SELECT g.d::DATE AS day) d
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND d.day BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        JOIN (SELECT DISTINCT pattern_detail_id, month, season_id FROM tariff_dev_v2.tou_pattern_detail) pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM d.day)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id = lnk.tariff_id AND r.rate_class_id = lnk.rate_class_id
          AND r.pattern_class_id = lnk.pattern_class_id AND r.attribute_collection_id = v_coll
          AND r.season_id = pd.season_id
          AND d.day BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
        GROUP BY d.day
    ),
    runs AS (
        SELECT x.day, x.rate,
               SUM(CASE WHEN x.rate IS DISTINCT FROM x.prev OR x.day <> x.prev_day + 1 THEN 1 ELSE 0 END) OVER (ORDER BY x.day) AS run_no
        FROM (SELECT dr.day, dr.rate, LAG(dr.rate) OVER (ORDER BY dr.day) AS prev, LAG(dr.day) OVER (ORDER BY dr.day) AS prev_day
              FROM day_rates dr) x
    ),
    segments AS (
        SELECT min(runs.day) AS segment_start, max(runs.day) AS segment_end, runs.rate, count(*) AS days_at_rate,
               SUM(count(*)) OVER () AS total_days
        FROM runs GROUP BY runs.run_no, runs.rate
    )
    SELECT EXTRACT(EPOCH FROM s.segment_end)::INT,
           ROUND((v_demand * s.rate / 100.0 * s.days_at_rate / s.total_days)::NUMERIC, 2)::FLOAT,
           ROUND(v_demand, 2)::FLOAT,
           ROUND((s.rate / 100.0)::NUMERIC, 4)::FLOAT,
           EXTRACT(EPOCH FROM v_demand_at)::INT,
           p_subsystem_cuid
    FROM segments s
    ORDER BY s.segment_start;
END
$$;


--
-- TOC entry 3158 (class 1255 OID 181700707)
-- Name: get_demand_charge_cost_with_minimum(integer, integer, integer[], text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_demand_charge_cost_with_minimum(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, demand double precision, rate double precision, demand_at integer, subsys text)
    LANGUAGE sql STABLE
    AS $$
    SELECT f.*
    FROM tariff_dev_v2.get_demand_charge_cost_from_binned_kva(
             p_tariff_id, p_rate_class_id, p_attribute_value_ids, p_subsystem_cuid, p_start_date, p_end_date,
             (SELECT r.rate FROM tariff_dev_v2.rates r JOIN tariff_dev_v2.rate_classes rc USING (rate_class_id)
              WHERE r.tariff_id = p_tariff_id AND rc.rate_key = 'minimum_demand_kva'
                AND tariff_dev_v2.local_date(p_end_date) BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
              ORDER BY r.valid_from DESC LIMIT 1)) f;
$$;


--
-- TOC entry 2534 (class 1255 OID 181700697)
-- Name: get_energy_charge_cost_from_std_val_hourly(text, integer, integer, text, timestamp without time zone, timestamp without time zone, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_energy_charge_cost_from_std_val_hourly(p_system_cuid text, p_tariff_id integer, p_rate_class_id integer, p_std_val_column text, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_attribute_value_ids integer[]) RETURNS TABLE("timestamp" integer, cost double precision, energy double precision, rate double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_collection INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids);
BEGIN
    RETURN QUERY EXECUTE format($sql$
        WITH in_data AS (
            SELECT sv."timestamp" AS raw_ts,
                   (sv."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' - INTERVAL '1 hour') AS ts,
                   sv.%1$I           AS value,
                   sv.subsystem_cuid AS subsys
            FROM hyper."SystemStandardValueLog" sv
            WHERE sv.system_cuid = $1
              AND sv."timestamp" BETWEEN $2 AND $3
              AND sv.%1$I IS NOT NULL
        )
        SELECT EXTRACT(EPOCH FROM id.raw_ts)::INT                                   AS "timestamp",
               ROUND((id.value * r.rate / 100.0)::NUMERIC, 2)::FLOAT  AS cost,
               ROUND(id.value::NUMERIC, 2)::FLOAT                                    AS energy,
               ROUND((r.rate / 100.0)::NUMERIC, 4)::FLOAT                            AS rate,
               id.subsys
        FROM in_data id
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = $4
          AND lnk.rate_class_id = $5
          AND id.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
          ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
          AND hol.holiday_date      = id.ts::DATE
        JOIN tariff_dev_v2.tou_pattern_detail pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM id.ts)::INT
          AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM id.ts)::INT)
          AND pd.hour  = EXTRACT(HOUR  FROM id.ts)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = $6
          AND r.season_id               = pd.season_id
          AND r.period_id               = pd.period_id
          AND id.ts::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
        ORDER BY id.raw_ts
    $sql$, p_std_val_column)
    USING p_system_cuid, p_start_date, p_end_date, p_tariff_id, p_rate_class_id, v_collection;
END
$_$;


--
-- TOC entry 3997 (class 1255 OID 181700726)
-- Name: get_excess_mec_charge_cost(text, integer, integer, integer[], numeric, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_excess_mec_charge_cost(p_system_cuid text, p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_mec numeric, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, max_export double precision, excess_kw double precision, event_number integer, deadband_exempt boolean, mec double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_ids    INT[] := tariff_dev_v2.attribute_value_ids_for(p_rate_class_id, p_attribute_value_ids);
    v_max    NUMERIC;
    v_free   BOOLEAN;
    v_events INT;
    v_cost   NUMERIC := 0;
BEGIN
    SELECT m.max_export, m.free INTO v_max, v_free
    FROM tariff_dev_v2.mec_months(p_system_cuid, p_mec, p_start_date, p_end_date) m
    WHERE m.k = 0 AND m.is_event;
    IF v_max IS NULL THEN
        RETURN;
    END IF;
    SELECT count(*) INTO v_events
    FROM tariff_dev_v2.mec_months(p_system_cuid, p_mec, p_start_date, p_end_date) m WHERE m.is_event;

    IF NOT v_free AND EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
                              JOIN tariff_dev_v2.attribute_collections c USING (attribute_collection_id)
                              WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
                                AND c.attribute_value_ids = v_ids) THEN
        v_cost := tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, v_ids, (v_max - p_mec) * v_events,
                                                   p_start_date, p_end_date);
    END IF;

    RETURN QUERY SELECT EXTRACT(EPOCH FROM p_end_date)::INT, ROUND(v_cost, 2)::FLOAT, ROUND(v_max, 2)::FLOAT,
                        ROUND(v_max - p_mec, 2)::FLOAT, v_events, v_free, p_mec::FLOAT, p_system_cuid;
END
$$;


--
-- TOC entry 3662 (class 1255 OID 181700704)
-- Name: get_excess_network_capacity_charge_cost(integer, integer, integer[], integer, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_excess_network_capacity_charge_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_notified_demand integer, p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, max_demand double precision, excess_kva double precision, event_number integer, deadband_exempt boolean, rate double precision, subsys text)
    LANGUAGE sql STABLE
    AS $$
    WITH months AS (        -- tariff_dev_v2.nmd_months: k = 0 is the billing month
        SELECT * FROM tariff_dev_v2.nmd_months(p_subsystem_cuid, p_notified_demand, p_start_date, p_end_date)
    ),
    billing AS (
        SELECT m.max_demand AS md,
               (SELECT count(*) FROM months e WHERE e.is_event)::INT AS event_number,
               m.deadband_exempt AS exempt
        FROM months m WHERE m.k = 0 AND m.is_event
    ),
    segments AS (
        SELECT r.rate,
               GREATEST(r.valid_from, lnk.valid_from, tariff_dev_v2.local_date(p_start_date))                    AS segment_start,
               LEAST(COALESCE(r.valid_to, 'infinity'::DATE),
                     COALESCE(lnk.valid_to, 'infinity'::DATE), tariff_dev_v2.local_date(p_end_date))             AS segment_end
        FROM tariff_dev_v2.tariff_tou_pattern_link lnk
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
        WHERE lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND r.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
          AND lnk.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(lnk.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
    ),
    with_days AS (
        SELECT s.*, (s.segment_end - s.segment_start + 1) AS days_at_rate,
               SUM(s.segment_end - s.segment_start + 1) OVER () AS total_days
        FROM segments s
        WHERE s.segment_end >= s.segment_start
    )
    SELECT EXTRACT(EPOCH FROM w.segment_end)::INT AS "timestamp",
           CASE WHEN b.exempt THEN 0
                ELSE ROUND(((b.md - p_notified_demand) * w.rate / 100.0 * b.event_number
                            * w.days_at_rate / w.total_days)::NUMERIC, 2) END::FLOAT AS cost,
           ROUND(b.md, 2)::FLOAT                          AS max_demand,
           ROUND(b.md - p_notified_demand, 2)::FLOAT      AS excess_kva,
           b.event_number,
           b.exempt                                       AS deadband_exempt,
           ROUND((w.rate / 100.0)::NUMERIC, 4)::FLOAT     AS rate,
           p_subsystem_cuid                               AS subsys
    FROM with_days w
    CROSS JOIN billing b
    ORDER BY w.segment_start;
$$;


--
-- TOC entry 3738 (class 1255 OID 181700717)
-- Name: get_losses_charge_dx_generators_from_std_val_hourly(text, integer, integer, text, timestamp without time zone, timestamp without time zone, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_losses_charge_dx_generators_from_std_val_hourly(p_system_cuid text, p_tariff_id integer, p_rate_class_id integer, p_std_val_column text, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_attribute_value_ids integer[]) RETURNS TABLE("timestamp" integer, cost double precision, energy double precision, rate double precision, loss_term double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_ids       INT[] := tariff_dev_v2.sorted_distinct_ids(coalesce(p_attribute_value_ids, '{}'));
    v_tlf_class INT;
    v_dlf_class INT;
    v_tlf_ids   INT[];
    v_dlf_ids   INT[];
    v_weps_coll INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, '{}');
    v_tlf_coll  INT;
    v_dlf_coll  INT;
BEGIN
    SELECT rate_class_id INTO v_tlf_class FROM tariff_dev_v2.rate_classes WHERE rate_key = 'transmission_loss_factor';
    SELECT rate_class_id INTO v_dlf_class FROM tariff_dev_v2.rate_classes WHERE rate_key = 'distribution_loss_factor';
    IF v_tlf_class IS NULL OR v_dlf_class IS NULL THEN
        RAISE EXCEPTION 'loss factor rate classes are missing';
    END IF;

    v_tlf_ids := tariff_dev_v2.attribute_value_ids_for(v_tlf_class, v_ids);
    v_dlf_ids := tariff_dev_v2.attribute_value_ids_for(v_dlf_class, v_ids);
    IF NOT v_ids <@ (v_tlf_ids || v_dlf_ids) THEN
        RAISE EXCEPTION 'distribution losses charge: attribute values % are not TZ or VS values',
            ARRAY(SELECT unnest(v_ids) EXCEPT SELECT unnest(v_tlf_ids || v_dlf_ids) ORDER BY 1);
    END IF;
    v_tlf_coll := tariff_dev_v2.attribute_collection_id(v_tlf_class, v_tlf_ids);
    v_dlf_coll := tariff_dev_v2.attribute_collection_id(v_dlf_class, v_dlf_ids);

    -- Dynamic SQL only for the column name.
    RETURN QUERY EXECUTE format($sql$
        WITH in_data AS (
            SELECT sv."timestamp" AS raw_ts,
                   (sv."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' - INTERVAL '1 hour') AS ts,
                   sv.%1$I         AS value,
                   sv.subsystem_cuid AS subsys
            FROM hyper."SystemStandardValueLog" sv
            WHERE sv.system_cuid = $1
              AND sv."timestamp" BETWEEN $2 AND $3
              AND sv.%1$I IS NOT NULL
        ),
        priced AS (
            SELECT id.raw_ts, id.value, id.subsys, w.rate AS weps,
                   (dlf.rate * tlf.rate - 1) AS loss_term
            FROM in_data id
            JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
              ON  lnk.tariff_id     = $4
              AND lnk.rate_class_id = $5
              AND id.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
            LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
              ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
              AND hol.holiday_date      = id.ts::DATE
            JOIN tariff_dev_v2.tou_pattern_detail pd
              ON  pd.pattern_detail_id = lnk.pattern_detail_id
              AND pd.month = EXTRACT(MONTH FROM id.ts)::INT
              AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM id.ts)::INT)
              AND pd.hour  = EXTRACT(HOUR  FROM id.ts)::INT
            JOIN tariff_dev_v2.rates w
              ON  w.tariff_id               = lnk.tariff_id
              AND w.rate_class_id           = lnk.rate_class_id
              AND w.pattern_class_id        = lnk.pattern_class_id
              AND w.attribute_collection_id = $6
              AND w.season_id               = pd.season_id
              AND w.period_id               = pd.period_id
              AND id.ts::DATE BETWEEN w.valid_from AND COALESCE(w.valid_to, 'infinity'::DATE)
            JOIN tariff_dev_v2.rates tlf      -- all year, all periods
              ON  tlf.tariff_id               = $4
              AND tlf.rate_class_id           = $7
              AND tlf.attribute_collection_id = $8
              AND id.ts::DATE BETWEEN tlf.valid_from AND COALESCE(tlf.valid_to, 'infinity'::DATE)
            JOIN tariff_dev_v2.rates dlf      -- all year, all periods
              ON  dlf.tariff_id               = $4
              AND dlf.rate_class_id           = $9
              AND dlf.attribute_collection_id = $10
              AND id.ts::DATE BETWEEN dlf.valid_from AND COALESCE(dlf.valid_to, 'infinity'::DATE)
        )
        SELECT EXTRACT(EPOCH FROM p.raw_ts)::INT                                   AS "timestamp",
               ROUND((-p.value * p.weps * p.loss_term / 100.0)::NUMERIC, 2)::FLOAT  AS cost,
               ROUND(p.value::NUMERIC, 2)::FLOAT                                    AS energy,
               ROUND((p.weps / 100.0)::NUMERIC, 4)::FLOAT                           AS rate,
               ROUND(p.loss_term::NUMERIC, 6)::FLOAT                                AS loss_term,
               p.subsys
        FROM priced p
        ORDER BY p.raw_ts
    $sql$, p_std_val_column)
    USING p_system_cuid, p_start_date, p_end_date, p_tariff_id, p_rate_class_id, v_weps_coll,
          v_tlf_class, v_tlf_coll, v_dlf_class, v_dlf_coll;
END
$_$;


--
-- TOC entry 2544 (class 1255 OID 181700719)
-- Name: get_losses_charge_tx_generators_from_std_val_hourly(text, integer, integer, text, timestamp without time zone, timestamp without time zone, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_losses_charge_tx_generators_from_std_val_hourly(p_system_cuid text, p_tariff_id integer, p_rate_class_id integer, p_std_val_column text, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_attribute_value_ids integer[]) RETURNS TABLE("timestamp" integer, cost double precision, energy double precision, rate double precision, loss_term double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_ids       INT[] := tariff_dev_v2.sorted_distinct_ids(coalesce(p_attribute_value_ids, '{}'));
    v_glf_class INT;
    v_glf_ids   INT[];
    v_weps_coll INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, '{}');
    v_glf_coll  INT;
BEGIN
    SELECT rate_class_id INTO v_glf_class FROM tariff_dev_v2.rate_classes WHERE rate_key = 'generator_loss_factor';
    IF v_glf_class IS NULL THEN
        RAISE EXCEPTION 'generator_loss_factor rate class is missing';
    END IF;

    v_glf_ids := tariff_dev_v2.attribute_value_ids_for(v_glf_class, v_ids);
    IF NOT v_ids <@ v_glf_ids THEN
        RAISE EXCEPTION 'Transmission losses charge: attribute values % are not GZ values',
            ARRAY(SELECT unnest(v_ids) EXCEPT SELECT unnest(v_glf_ids) ORDER BY 1);
    END IF;
    v_glf_coll := tariff_dev_v2.attribute_collection_id(v_glf_class, v_glf_ids);

    -- Dynamic SQL only for the column name.
    RETURN QUERY EXECUTE format($sql$
        WITH in_data AS (
            SELECT sv."timestamp" AS raw_ts,
                   (sv."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' - INTERVAL '1 hour') AS ts,
                   sv.%1$I         AS value,
                   sv.subsystem_cuid AS subsys
            FROM hyper."SystemStandardValueLog" sv
            WHERE sv.system_cuid = $1
              AND sv."timestamp" BETWEEN $2 AND $3
              AND sv.%1$I IS NOT NULL
        ),
        priced AS (
            SELECT id.raw_ts, id.value, id.subsys, w.rate AS weps,
                   ((glf.rate - 1) / glf.rate) AS loss_term
            FROM in_data id
            JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
              ON  lnk.tariff_id     = $4
              AND lnk.rate_class_id = $5
              AND id.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
            LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
              ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
              AND hol.holiday_date      = id.ts::DATE
            JOIN tariff_dev_v2.tou_pattern_detail pd
              ON  pd.pattern_detail_id = lnk.pattern_detail_id
              AND pd.month = EXTRACT(MONTH FROM id.ts)::INT
              AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM id.ts)::INT)
              AND pd.hour  = EXTRACT(HOUR  FROM id.ts)::INT
            JOIN tariff_dev_v2.rates w
              ON  w.tariff_id               = lnk.tariff_id
              AND w.rate_class_id           = lnk.rate_class_id
              AND w.pattern_class_id        = lnk.pattern_class_id
              AND w.attribute_collection_id = $6
              AND w.season_id               = pd.season_id
              AND w.period_id               = pd.period_id
              AND id.ts::DATE BETWEEN w.valid_from AND COALESCE(w.valid_to, 'infinity'::DATE)
            JOIN tariff_dev_v2.rates glf      -- all year, all periods
              ON  glf.tariff_id               = $4
              AND glf.rate_class_id           = $7
              AND glf.attribute_collection_id = $8
              AND id.ts::DATE BETWEEN glf.valid_from AND COALESCE(glf.valid_to, 'infinity'::DATE)
        )
        SELECT EXTRACT(EPOCH FROM p.raw_ts)::INT                                   AS "timestamp",
               ROUND((-p.value * p.weps * p.loss_term / 100.0)::NUMERIC, 2)::FLOAT  AS cost,
               ROUND(p.value::NUMERIC, 2)::FLOAT                                    AS energy,
               ROUND((p.weps / 100.0)::NUMERIC, 4)::FLOAT                           AS rate,
               ROUND(p.loss_term::NUMERIC, 6)::FLOAT                                AS loss_term,
               p.subsys
        FROM priced p
        ORDER BY p.raw_ts
    $sql$, p_std_val_column)
    USING p_system_cuid, p_start_date, p_end_date, p_tariff_id, p_rate_class_id, v_weps_coll,
          v_glf_class, v_glf_coll;
END
$_$;


--
-- TOC entry 2880 (class 1255 OID 181700727)
-- Name: get_monthly_charge_cost(integer, integer, integer[], timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_monthly_charge_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, rate double precision)
    LANGUAGE sql STABLE
    AS $$
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, p_attribute_value_ids, 1, p_start_date, p_end_date)::FLOAT,
           (SELECT ROUND(r.rate / 100.0, 4)::FLOAT
            FROM tariff_dev_v2.rates r
            WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
              AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
              AND tariff_dev_v2.local_date(p_end_date) BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
            ORDER BY r.valid_from DESC LIMIT 1)
    WHERE EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
                  WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
                    AND r.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date));
$$;


--
-- TOC entry 2900 (class 1255 OID 181700722)
-- Name: get_network_charge_topup_dx_generators(text, text, integer, integer, integer[], numeric, integer, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_network_charge_topup_dx_generators(p_system_cuid text, p_subsystem_cuid text, p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_mec numeric, p_notified_demand integer, p_std_val_column text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, generator_charge double precision, losses_rebate double precision, generator_side double precision, load_side double precision, transmission_network double precision, distribution_capacity double precision, distribution_demand double precision, mec double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_ids     INT[] := tariff_dev_v2.sorted_distinct_ids(coalesce(p_attribute_value_ids, '{}'));
    v_tx      INT;  v_dx  INT;  v_dd  INT;  v_weps INT;  v_tlf INT;  v_dlf INT;
    v_gen     NUMERIC;  v_losses NUMERIC;  v_tx_cost NUMERIC;  v_dx_cost NUMERIC;  v_dd_cost NUMERIC;
    v_gen_side NUMERIC; v_load NUMERIC;
BEGIN
    SELECT rate_class_id INTO v_tx   FROM tariff_dev_v2.rate_classes WHERE rate_key = 'transmission_network_charge';
    SELECT rate_class_id INTO v_dx   FROM tariff_dev_v2.rate_classes WHERE rate_key = 'distribution_net_capacity_charge';
    SELECT rate_class_id INTO v_dd   FROM tariff_dev_v2.rate_classes WHERE rate_key = 'distribution_net_demand_charge_kva';
    SELECT rate_class_id INTO v_weps FROM tariff_dev_v2.rate_classes WHERE rate_key = 'weps_energy_rate_excl_losses';
    SELECT rate_class_id INTO v_tlf  FROM tariff_dev_v2.rate_classes WHERE rate_key = 'transmission_loss_factor';
    SELECT rate_class_id INTO v_dlf  FROM tariff_dev_v2.rate_classes WHERE rate_key = 'distribution_loss_factor';
    IF NOT v_ids <@ (tariff_dev_v2.attribute_value_ids_for(v_tx, v_ids) || tariff_dev_v2.attribute_value_ids_for(p_rate_class_id, v_ids)) THEN
        RAISE EXCEPTION 'network charge top-up (dx generators): attribute values % are not TZ or VS values', v_ids;
    END IF;

    IF EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
               JOIN tariff_dev_v2.attribute_collections c USING (attribute_collection_id)
               WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
                 AND c.attribute_value_ids = tariff_dev_v2.attribute_value_ids_for(p_rate_class_id, v_ids)) THEN
        v_gen := tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, tariff_dev_v2.attribute_value_ids_for(p_rate_class_id, v_ids),
                                                  p_mec, p_start_date, p_end_date);
    ELSE
        v_gen := 0;     -- no generator rate published for this voltage
    END IF;

    SELECT coalesce(sum(f.cost), 0) INTO v_losses
    FROM tariff_dev_v2.get_losses_charge_dx_generators_from_std_val_hourly(
        p_system_cuid, p_tariff_id, v_weps, p_std_val_column, p_start_date, p_end_date,
        tariff_dev_v2.attribute_value_ids_for(v_tlf, v_ids) || tariff_dev_v2.attribute_value_ids_for(v_dlf, v_ids)) f;

    SELECT coalesce(sum(f.cost), 0) INTO v_tx_cost
    FROM tariff_dev_v2.get_capacity_charge_cost_from_auc(p_tariff_id, v_tx, tariff_dev_v2.attribute_value_ids_for(v_tx, v_ids),
                                                         p_notified_demand, p_subsystem_cuid, p_start_date, p_end_date) f;
    SELECT coalesce(sum(f.cost), 0) INTO v_dx_cost
    FROM tariff_dev_v2.get_capacity_charge_cost_from_auc(p_tariff_id, v_dx, tariff_dev_v2.attribute_value_ids_for(v_dx, v_ids),
                                                         p_notified_demand, p_subsystem_cuid, p_start_date, p_end_date) f;
    SELECT coalesce(sum(f.cost), 0) INTO v_dd_cost
    FROM tariff_dev_v2.get_demand_charge_cost_from_binned_kva(p_tariff_id, v_dd, tariff_dev_v2.attribute_value_ids_for(v_dd, v_ids),
                                                              p_subsystem_cuid, p_start_date, p_end_date) f;

    v_gen_side := GREATEST(v_gen + v_losses, 0);
    v_load     := v_tx_cost + v_dx_cost + v_dd_cost;

    RETURN QUERY SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
                        ROUND(GREATEST(v_gen_side - v_load, 0), 2)::FLOAT,
                        ROUND(v_gen, 2)::FLOAT, ROUND(v_losses, 2)::FLOAT, ROUND(v_gen_side, 2)::FLOAT, ROUND(v_load, 2)::FLOAT,
                        ROUND(v_tx_cost, 2)::FLOAT, ROUND(v_dx_cost, 2)::FLOAT, ROUND(v_dd_cost, 2)::FLOAT,
                        p_mec::FLOAT, p_subsystem_cuid;
END
$$;


--
-- TOC entry 2545 (class 1255 OID 181700724)
-- Name: get_network_charge_topup_tx_generators(text, integer, integer, integer[], numeric, integer, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_network_charge_topup_tx_generators(p_subsystem_cuid text, p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_mec numeric, p_notified_demand integer, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, generator_side double precision, load_side double precision, mec double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_ids   INT[] := tariff_dev_v2.sorted_distinct_ids(coalesce(p_attribute_value_ids, '{}'));
    v_tx    INT;
    v_gen   NUMERIC;
    v_load  NUMERIC;
BEGIN
    SELECT rate_class_id INTO v_tx FROM tariff_dev_v2.rate_classes WHERE rate_key = 'transmission_network_charge';
    IF NOT v_ids <@ (tariff_dev_v2.attribute_value_ids_for(v_tx, v_ids) || tariff_dev_v2.attribute_value_ids_for(p_rate_class_id, v_ids)) THEN
        RAISE EXCEPTION 'network charge top-up (tx generators): attribute values % are not TZ, VS or GZ values', v_ids;
    END IF;

    v_gen := tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, tariff_dev_v2.attribute_value_ids_for(p_rate_class_id, v_ids),
                                              p_mec, p_start_date, p_end_date);
    SELECT coalesce(sum(f.cost), 0) INTO v_load
    FROM tariff_dev_v2.get_capacity_charge_cost_from_auc(p_tariff_id, v_tx, tariff_dev_v2.attribute_value_ids_for(v_tx, v_ids),
                                                         p_notified_demand, p_subsystem_cuid, p_start_date, p_end_date) f;

    RETURN QUERY SELECT EXTRACT(EPOCH FROM p_end_date)::INT, ROUND(GREATEST(v_gen - v_load, 0), 2)::FLOAT,
                        ROUND(v_gen, 2)::FLOAT, ROUND(v_load, 2)::FLOAT, p_mec::FLOAT, p_subsystem_cuid;
END
$$;


--
-- TOC entry 2982 (class 1255 OID 181700728)
-- Name: get_nmd_charge_cost(integer, integer, integer[], integer, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_nmd_charge_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_notified_demand integer, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, nmd double precision)
    LANGUAGE sql STABLE
    AS $$
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, p_attribute_value_ids, p_notified_demand,
                                            p_start_date, p_end_date)::FLOAT,
           p_notified_demand::FLOAT
    WHERE EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
                  WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
                    AND r.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date));
$$;


--
-- TOC entry 2897 (class 1255 OID 181700732)
-- Name: get_nmd_exceedance_charge_overstrand(integer, integer, integer[], integer, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_nmd_exceedance_charge_overstrand(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_notified_demand integer, p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, max_demand double precision, excess_kva double precision, warning boolean, subsys text)
    LANGUAGE sql STABLE
    AS $$
    WITH months AS (
        SELECT m.k,
               CASE WHEN m.k = 0 THEN p_start_date ELSE tariff_dev_v2.local_months_before(p_start_date, m.k) END        AS m_start,
               CASE WHEN m.k = 0 THEN p_end_date
                    ELSE tariff_dev_v2.local_months_before(p_start_date, m.k - 1) - INTERVAL '1 millisecond' END      AS m_end
        FROM generate_series(0, 12) m(k)
    ),
    md AS (
        SELECT m.k, max(elem.value::NUMERIC) AS md
        FROM months m
        JOIN hyper."SystemStandardValueLog" sv
          ON  sv.subsystem_cuid = p_subsystem_cuid
          AND sv."timestamp" BETWEEN m.m_start AND m.m_end
          AND sv.extensions -> 'binned_30_kva' IS NOT NULL
        CROSS JOIN LATERAL jsonb_array_elements(sv.extensions -> 'binned_30_kva') AS elem(value)
        GROUP BY m.k
    ),
    billing AS (
        SELECT md.md, NOT EXISTS (SELECT 1 FROM md e WHERE e.k BETWEEN 1 AND 12 AND e.md > p_notified_demand) AS warning
        FROM md WHERE md.k = 0 AND md.md > p_notified_demand
    )
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           CASE WHEN b.warning THEN 0
                ELSE tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, p_attribute_value_ids, b.md - p_notified_demand,
                                                      p_start_date, p_end_date) END::FLOAT,
           ROUND(b.md, 2)::FLOAT, ROUND(b.md - p_notified_demand, 2)::FLOAT, b.warning, p_subsystem_cuid
    FROM billing b;
$$;


--
-- TOC entry 3258 (class 1255 OID 181700729)
-- Name: get_nmd_exceedance_surcharge_municipal(integer, integer, integer[], integer, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_nmd_exceedance_surcharge_municipal(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_notified_demand integer, p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, max_demand double precision, occasion integer, surcharge_pct integer, nmd_charge double precision, disconnection_risk boolean, subsys text)
    LANGUAGE sql STABLE
    AS $$
    WITH fy AS (
        SELECT make_date(EXTRACT(YEAR FROM l)::INT - CASE WHEN EXTRACT(MONTH FROM l) < 7 THEN 1 ELSE 0 END, 7, 1)::TIMESTAMP AS fy_start
        FROM (SELECT (p_start_date AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg') AS l) x
    ),
    months AS (
        SELECT m.k,
               CASE WHEN m.k = 0 THEN p_start_date ELSE tariff_dev_v2.local_months_before(p_start_date, m.k) END        AS m_start,
               CASE WHEN m.k = 0 THEN p_end_date
                    ELSE tariff_dev_v2.local_months_before(p_start_date, m.k - 1) - INTERVAL '1 millisecond' END      AS m_end
        FROM generate_series(0, 11) m(k)
    ),
    in_fy AS (              -- the billing month, and earlier months that start in the same financial year
        SELECT m.* FROM months m, fy
        WHERE m.k = 0 OR (m.m_start AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg') >= fy.fy_start
    ),
    md AS (
        SELECT m.k, max(elem.value::NUMERIC) AS md
        FROM in_fy m
        JOIN hyper."SystemStandardValueLog" sv
          ON  sv.subsystem_cuid = p_subsystem_cuid
          AND sv."timestamp" BETWEEN m.m_start AND m.m_end
          AND sv.extensions -> 'binned_30_kva' IS NOT NULL
        CROSS JOIN LATERAL jsonb_array_elements(sv.extensions -> 'binned_30_kva') AS elem(value)
        GROUP BY m.k
    ),
    billing AS (
        SELECT md.md, (SELECT count(*) FROM md e WHERE e.md > p_notified_demand)::INT AS occasion
        FROM md WHERE md.k = 0 AND md.md > p_notified_demand
    ),
    step AS (               -- % per occasion, in force on the interval's last local day
        SELECT r.rate FROM tariff_dev_v2.rates r
        WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
          AND tariff_dev_v2.local_date(p_end_date) BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    ),
    charge AS (
        SELECT COALESCE((SELECT sum(c.cost)
                         FROM tariff_dev_v2.get_nmd_charge_cost(p_tariff_id,
                                  (SELECT rate_class_id FROM tariff_dev_v2.rate_classes WHERE rate_key = 'nmd_charge'),
                                  NULL, p_notified_demand, p_start_date, p_end_date) c), 0)::NUMERIC AS nmd_charge
    )
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           ROUND(c.nmd_charge * x.pct / 100.0, 2)::FLOAT,
           ROUND(b.md, 2)::FLOAT, b.occasion, x.pct, ROUND(c.nmd_charge, 2)::FLOAT, b.occasion >= 5, p_subsystem_cuid
    FROM billing b CROSS JOIN charge c CROSS JOIN step s
    CROSS JOIN LATERAL (SELECT (LEAST(b.occasion - 1, 3) * s.rate)::INT AS pct) x;
$$;


--
-- TOC entry 2930 (class 1255 OID 181700711)
-- Name: get_rate_at_interval_end(integer, integer, integer[], timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_rate_at_interval_end(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, rate double precision)
    LANGUAGE sql STABLE
    AS $$
    SELECT EXTRACT(EPOCH FROM tariff_dev_v2.local_date(p_end_date))::INT AS "timestamp",
           ROUND((r.rate / 100.0)::NUMERIC, 4)::FLOAT AS rate
    FROM tariff_dev_v2.tariff_tou_pattern_link lnk
    JOIN tariff_dev_v2.rates r
      ON  r.tariff_id               = lnk.tariff_id
      AND r.rate_class_id           = lnk.rate_class_id
      AND r.pattern_class_id        = lnk.pattern_class_id
      AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
    WHERE lnk.tariff_id     = p_tariff_id
      AND lnk.rate_class_id = p_rate_class_id
      AND tariff_dev_v2.local_date(p_end_date) BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
      AND tariff_dev_v2.local_date(p_end_date) BETWEEN r.valid_from  AND COALESCE(r.valid_to,  'infinity'::DATE);
$$;


--
-- TOC entry 3577 (class 1255 OID 181700709)
-- Name: get_rate_eras_for_interval(integer, integer, integer[], timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_rate_eras_for_interval(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, rate double precision)
    LANGUAGE sql STABLE
    AS $$
    WITH eras AS (
        SELECT r.valid_from,
               LEAST(COALESCE(r.valid_to, 'infinity'::DATE), tariff_dev_v2.local_date(p_end_date)) AS last_day,
               r.rate
        FROM tariff_dev_v2.tariff_tou_pattern_link lnk
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
        WHERE lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND r.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
          AND lnk.valid_from <= tariff_dev_v2.local_date(p_end_date) AND COALESCE(lnk.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date)
    ),
    runs AS (
        SELECT last_day, rate,
               SUM(CASE WHEN rate IS DISTINCT FROM prev_rate THEN 1 ELSE 0 END) OVER (ORDER BY valid_from) AS run_no
        FROM (SELECT valid_from, last_day, rate, LAG(rate) OVER (ORDER BY valid_from) AS prev_rate FROM eras) lagged
    )
    SELECT EXTRACT(EPOCH FROM MAX(last_day))::INT AS "timestamp",
           ROUND((rate / 100.0)::NUMERIC, 4)::FLOAT AS rate
    FROM runs
    GROUP BY run_no, rate
    ORDER BY "timestamp";
$$;


--
-- TOC entry 2600 (class 1255 OID 181700713)
-- Name: get_reactive_energy_charge_cost(integer, integer, integer[], text, text, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_reactive_energy_charge_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_entity_cuid text, p_kwh_parameter_id text, p_kvarh_parameter_id text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, kvarh double precision, kwh double precision, excess_kvarh double precision, rate double precision, season_id integer)
    LANGUAGE sql STABLE
    AS $$
    WITH reg AS (
        SELECT p.parameter_id,
               (SELECT pl.value FROM hyper."ParameterLog" pl
                WHERE pl.entity_cuid = p_entity_cuid AND pl.parameter_id = p.parameter_id
                  AND pl."timestamp" BETWEEN p_end_date - INTERVAL '1 day' AND p_end_date
                ORDER BY pl."timestamp" DESC LIMIT 1)
             - (SELECT pl.value FROM hyper."ParameterLog" pl
                WHERE pl.entity_cuid = p_entity_cuid AND pl.parameter_id = p.parameter_id
                  AND pl."timestamp" BETWEEN p_start_date - INTERVAL '1 day' AND p_start_date
                ORDER BY pl."timestamp" DESC LIMIT 1) AS total
        FROM (VALUES (p_kwh_parameter_id), (p_kvarh_parameter_id)) p(parameter_id)
    ),
    totals AS (
        SELECT max(total) FILTER (WHERE parameter_id = p_kwh_parameter_id)   AS kwh,
               max(total) FILTER (WHERE parameter_id = p_kvarh_parameter_id) AS kvarh
        FROM reg
    ),
    excess AS (
        SELECT kwh, kvarh, GREATEST(kvarh - 0.30 * kwh, 0) AS excess_kvarh
        FROM totals
        WHERE kwh IS NOT NULL AND kvarh IS NOT NULL
    ),
    days AS (
        -- each day of the billing period with its season and rate (season depends on month only)
        SELECT DISTINCT d.day::DATE AS day, pd.season_id, r.rate
        FROM generate_series(tariff_dev_v2.local_date(p_start_date), tariff_dev_v2.local_date(p_end_date), INTERVAL '1 day') AS d(day)
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND d.day::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        JOIN tariff_dev_v2.tou_pattern_detail pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM d.day)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids)
          AND r.season_id               = pd.season_id
          AND d.day::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    ),
    segments AS (
        SELECT season_id, rate, max(day) AS last_day, count(*) AS days_at_rate
        FROM (SELECT d.*, SUM(CASE WHEN (d.season_id, d.rate) IS DISTINCT FROM (d.prev_season, d.prev_rate) THEN 1 ELSE 0 END)
                             OVER (ORDER BY d.day) AS seg
              FROM (SELECT days.*, LAG(season_id) OVER (ORDER BY day) AS prev_season,
                                   LAG(rate)      OVER (ORDER BY day) AS prev_rate
                    FROM days) d) x
        GROUP BY seg, season_id, rate
    )
    SELECT EXTRACT(EPOCH FROM s.last_day)::INT AS "timestamp",
           ROUND((e.excess_kvarh * s.days_at_rate / sum(s.days_at_rate) OVER ()
                  * s.rate / 100.0)::NUMERIC, 2)::FLOAT AS cost,
           ROUND(e.kvarh::NUMERIC, 2)::FLOAT        AS kvarh,
           ROUND(e.kwh::NUMERIC, 2)::FLOAT          AS kwh,
           ROUND(e.excess_kvarh::NUMERIC, 2)::FLOAT AS excess_kvarh,
           ROUND((s.rate / 100.0)::NUMERIC, 4)::FLOAT AS rate,
           s.season_id
    FROM segments s
    CROSS JOIN excess e
    ORDER BY s.last_day;
$$;


--
-- TOC entry 2747 (class 1255 OID 181700715)
-- Name: get_reactive_energy_charge_cost_30min(integer, integer, integer[], text, text, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_reactive_energy_charge_cost_30min(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_entity_cuid text, p_kwh_parameter_id text, p_kvarh_parameter_id text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, kvarh double precision, kwh double precision, excess_kvarh double precision, rate double precision, season_id integer, periods integer, missing_periods integer)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_coll INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids);
BEGIN
    RETURN QUERY
    WITH readings AS (      -- the last reading at or before each :00 / :30, within 5 minutes
        SELECT DISTINCT ON (pl.parameter_id, b.boundary)
               pl.parameter_id, b.boundary, pl.value
        FROM hyper."ParameterLog" pl
        CROSS JOIN LATERAL (SELECT date_bin(INTERVAL '30 minutes', pl."timestamp" + INTERVAL '30 minutes' - INTERVAL '1 millisecond',
                                            TIMESTAMP '2000-01-01') AS boundary) b
        WHERE pl.entity_cuid = p_entity_cuid
          AND pl.parameter_id IN (p_kwh_parameter_id, p_kvarh_parameter_id)
          AND pl."timestamp" BETWEEN p_start_date - INTERVAL '5 minutes' AND p_end_date
          AND pl."timestamp" >= b.boundary - INTERVAL '5 minutes'
        ORDER BY pl.parameter_id, b.boundary, pl."timestamp" DESC
    ),
    reg AS (
        SELECT boundary,
               max(value) FILTER (WHERE parameter_id = p_kwh_parameter_id)   AS kwh,
               max(value) FILTER (WHERE parameter_id = p_kvarh_parameter_id) AS kvarh
        FROM readings GROUP BY boundary
    ),
    periods AS (            -- 30-minute periods inside the interval, priced by their local start
        SELECT e.period_end,
               ((e.period_end - INTERVAL '30 minutes') AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg') AS ts
        FROM generate_series(date_bin(INTERVAL '30 minutes', p_start_date + INTERVAL '30 minutes' - INTERVAL '1 millisecond', TIMESTAMP '2000-01-01')
                                 + INTERVAL '30 minutes',
                             date_bin(INTERVAL '30 minutes', p_end_date, TIMESTAMP '2000-01-01'),
                             INTERVAL '30 minutes') AS e(period_end)
    ),
    chargeable AS (
        SELECT p.period_end, r.season_id, r.valid_from, r.rate,
               re.kwh - rs.kwh AS d_kwh, re.kvarh - rs.kvarh AS d_kvarh
        FROM periods p
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND p.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
          ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
          AND hol.holiday_date      = p.ts::DATE
        JOIN tariff_dev_v2.tou_pattern_detail pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM p.ts)::INT
          AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM p.ts)::INT)
          AND pd.hour  = EXTRACT(HOUR  FROM p.ts)::INT
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = v_coll
          AND r.season_id               = pd.season_id
          AND r.period_id               = pd.period_id
          AND p.ts::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
        LEFT JOIN reg rs ON rs.boundary = p.period_end - INTERVAL '30 minutes'
        LEFT JOIN reg re ON re.boundary = p.period_end
    ),
    judged AS (
        SELECT c.*, (c.d_kwh IS NOT NULL AND c.d_kvarh IS NOT NULL AND c.d_kwh >= 0 AND c.d_kvarh >= 0) AS ok
        FROM chargeable c
    )
    SELECT EXTRACT(EPOCH FROM max(j.period_end))::INT,
           ROUND((COALESCE(sum(GREATEST(j.d_kvarh - 0.30 * j.d_kwh, 0)) FILTER (WHERE j.ok), 0)
                  * j.rate / 100.0)::NUMERIC, 2)::FLOAT,
           ROUND(COALESCE(sum(j.d_kvarh) FILTER (WHERE j.ok), 0)::NUMERIC, 2)::FLOAT,
           ROUND(COALESCE(sum(j.d_kwh) FILTER (WHERE j.ok), 0)::NUMERIC, 2)::FLOAT,
           ROUND(COALESCE(sum(GREATEST(j.d_kvarh - 0.30 * j.d_kwh, 0)) FILTER (WHERE j.ok), 0)::NUMERIC, 2)::FLOAT,
           ROUND((j.rate / 100.0)::NUMERIC, 4)::FLOAT,
           j.season_id,
           (count(*) FILTER (WHERE j.ok))::INT,
           (count(*) FILTER (WHERE NOT j.ok))::INT
    FROM judged j
    GROUP BY j.season_id, j.valid_from, j.rate
    HAVING count(*) FILTER (WHERE j.ok) > 0
    ORDER BY max(j.period_end);
END
$$;


--
-- TOC entry 2465 (class 1255 OID 181700696)
-- Name: get_tou_cost_and_energy_from_kw(text, text, timestamp without time zone, timestamp without time zone, integer, integer, integer, shared_types.power_direction_type, integer, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_tou_cost_and_energy_from_kw(p_entity_id text, p_parameter_id text, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_tariff_id integer, p_rate_class_id integer, p_period_id integer, p_above_below_both shared_types.power_direction_type, p_interval_minutes integer DEFAULT 1, p_attribute_value_ids integer[] DEFAULT NULL::integer[]) RETURNS TABLE("timestamp" integer, energy double precision, cost double precision)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_collection INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids);
BEGIN
    RETURN QUERY
    WITH in_data AS (
        SELECT (hp."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg') AS ts,
               hp.value * p_interval_minutes / 60.0                                  AS kwh
        FROM hyper."ParameterLog" hp
        WHERE hp.entity_cuid  = p_entity_id
          AND hp.parameter_id = p_parameter_id
          AND hp."timestamp" BETWEEN p_start_date AND p_end_date
          AND (p_above_below_both = 'both'
               OR (p_above_below_both = 'above' AND hp.value > 0)
               OR (p_above_below_both = 'below' AND hp.value < 0))
    ),
    priced AS (
        SELECT id.kwh, r.rate
        FROM in_data id
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND id.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
          ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
          AND hol.holiday_date      = id.ts::DATE
        JOIN tariff_dev_v2.tou_pattern_detail pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM id.ts)::INT
          AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM id.ts)::INT)
          AND pd.hour  = EXTRACT(HOUR  FROM id.ts)::INT
          AND (p_period_id = 0 OR pd.period_id = p_period_id)
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = v_collection
          AND r.season_id               = pd.season_id
          AND r.period_id               = pd.period_id
          AND id.ts::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    )
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           ROUND(ABS(SUM(p.kwh))::NUMERIC, 2)::FLOAT,
           ROUND(ABS(SUM(p.kwh * p.rate / 100.0))::NUMERIC, 2)::FLOAT
    FROM priced p;
END
$$;


--
-- TOC entry 3155 (class 1255 OID 181700695)
-- Name: get_tou_period_cost_from_std_val_hourly(text, integer, integer, integer, text, timestamp without time zone, timestamp without time zone, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_tou_period_cost_from_std_val_hourly(p_system_cuid text, p_tariff_id integer, p_rate_class_id integer, p_period_id integer, p_std_val_column text, p_start_date timestamp without time zone, p_end_date timestamp without time zone, p_attribute_value_ids integer[]) RETURNS TABLE("timestamp" integer, cost double precision, energy double precision, rate double precision, subsys text)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_collection INT := tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids);
BEGIN
    -- Dynamic SQL only for the column name.
    RETURN QUERY EXECUTE format($sql$
        WITH in_data AS (
            SELECT sv."timestamp" AS raw_ts,
                   (sv."timestamp" AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' - INTERVAL '1 hour') AS ts,
                   sv.%1$I         AS value,
                   sv.subsystem_cuid AS subsys
            FROM hyper."SystemStandardValueLog" sv
            WHERE sv.system_cuid = $1
              AND sv."timestamp" BETWEEN $2 AND $3
              AND sv.%1$I IS NOT NULL
        )
        SELECT EXTRACT(EPOCH FROM id.raw_ts)::INT                      AS "timestamp",
               ROUND((id.value * r.rate / 100.0)::NUMERIC, 2)::FLOAT    AS cost,
               ROUND(id.value::NUMERIC, 2)::FLOAT                       AS energy,
               ROUND((r.rate / 100.0)::NUMERIC, 2)::FLOAT               AS rate,
               id.subsys
        FROM in_data id
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = $4
          AND lnk.rate_class_id = $5
          AND id.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
          ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
          AND hol.holiday_date      = id.ts::DATE
        JOIN tariff_dev_v2.tou_pattern_detail pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM id.ts)::INT
          AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM id.ts)::INT)
          AND pd.hour  = EXTRACT(HOUR  FROM id.ts)::INT
          AND ($6 = 0 OR pd.period_id = $6)
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = lnk.tariff_id
          AND r.rate_class_id           = lnk.rate_class_id
          AND r.pattern_class_id        = lnk.pattern_class_id
          AND r.attribute_collection_id = $7
          AND r.season_id               = pd.season_id
          AND r.period_id               = pd.period_id
          AND id.ts::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
        ORDER BY id.raw_ts
    $sql$, p_std_val_column)
    USING p_system_cuid, p_start_date, p_end_date, p_tariff_id, p_rate_class_id, p_period_id, v_collection;
END
$_$;


--
-- TOC entry 3057 (class 1255 OID 181700712)
-- Name: get_tou_rate_at_interval_end(timestamp without time zone, integer, integer, integer, integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_tou_rate_at_interval_end(p_end_date timestamp without time zone, p_tariff_id integer, p_rate_class_id integer, p_period_id integer, p_attribute_value_ids integer[] DEFAULT NULL::integer[]) RETURNS TABLE("timestamp" integer, rate double precision, season_name text, period_name text)
    LANGUAGE sql STABLE
    AS $$
    WITH t AS (
        SELECT p_end_date AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg' AS ts,
               tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids) AS coll
    )
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           ROUND((r.rate / 100.0)::NUMERIC, 4)::FLOAT,
           s.season_name::TEXT,
           p.period_name::TEXT
    FROM t
    JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
      ON  lnk.tariff_id     = p_tariff_id
      AND lnk.rate_class_id = p_rate_class_id
      AND t.ts::DATE BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
    LEFT JOIN tariff_dev_v2.holiday_scheme_days hol   -- public holiday: the TOU day it is treated as
      ON  hol.holiday_scheme_id = lnk.holiday_scheme_id
      AND hol.holiday_date      = t.ts::DATE
    JOIN tariff_dev_v2.tou_pattern_detail pd
      ON  pd.pattern_detail_id = lnk.pattern_detail_id
      AND pd.month = EXTRACT(MONTH FROM t.ts)::INT
      AND pd.dow   = COALESCE(hol.treated_dow, EXTRACT(DOW FROM t.ts)::INT)
      AND pd.hour  = EXTRACT(HOUR  FROM t.ts)::INT
    JOIN tariff_dev_v2.rates r
      ON  r.tariff_id               = lnk.tariff_id
      AND r.rate_class_id           = lnk.rate_class_id
      AND r.pattern_class_id        = lnk.pattern_class_id
      AND r.attribute_collection_id = t.coll
      AND r.season_id               = pd.season_id
      AND r.period_id               = CASE WHEN p_period_id = 0 THEN pd.period_id ELSE p_period_id END
      AND t.ts::DATE BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    JOIN tariff_dev_v2.tou_seasons s ON s.season_id = r.season_id
    JOIN tariff_dev_v2.tou_periods p ON p.period_id = r.period_id;
$$;


--
-- TOC entry 2462 (class 1255 OID 181700694)
-- Name: get_tou_rates_for_interval(integer, integer, integer[], timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_tou_rates_for_interval(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, season_id integer, season_name text, period_id integer, period_name text, rate double precision)
    LANGUAGE sql STABLE
    AS $$
    WITH coll AS (
        SELECT tariff_dev_v2.attribute_collection_id(p_rate_class_id, p_attribute_value_ids) AS id
    ),
    days AS (
        SELECT d::DATE AS day
        FROM generate_series(tariff_dev_v2.local_date(p_start_date), tariff_dev_v2.local_date(p_end_date), INTERVAL '1 day') AS d
    ),
    day_seasons AS (
        -- Season depends on month only, so dow/hour aren't needed here.
        SELECT DISTINCT dy.day, lnk.pattern_class_id, pd.season_id
        FROM days dy
        JOIN tariff_dev_v2.tariff_tou_pattern_link lnk
          ON  lnk.tariff_id     = p_tariff_id
          AND lnk.rate_class_id = p_rate_class_id
          AND dy.day BETWEEN lnk.valid_from AND COALESCE(lnk.valid_to, 'infinity'::DATE)
        JOIN tariff_dev_v2.tou_pattern_detail pd
          ON  pd.pattern_detail_id = lnk.pattern_detail_id
          AND pd.month = EXTRACT(MONTH FROM dy.day)::INT
    ),
    day_rates AS (
        SELECT ds.day, ds.season_id, r.period_id, r.rate
        FROM day_seasons ds
        CROSS JOIN coll
        JOIN tariff_dev_v2.rates r
          ON  r.tariff_id               = p_tariff_id
          AND r.rate_class_id           = p_rate_class_id
          AND r.pattern_class_id        = ds.pattern_class_id
          AND r.attribute_collection_id = coll.id
          AND r.season_id               = ds.season_id
          AND ds.day BETWEEN r.valid_from AND COALESCE(r.valid_to, 'infinity'::DATE)
    ),
    lagged AS (
        SELECT day, season_id, period_id, rate,
               LAG(rate)      OVER (PARTITION BY period_id ORDER BY day) AS prev_rate,
               LAG(season_id) OVER (PARTITION BY period_id ORDER BY day) AS prev_season_id
        FROM day_rates
    ),
    runs AS (
        -- Gaps and islands: a new run starts whenever the rate or the season changes.
        SELECT day, season_id, period_id, rate,
               SUM(CASE WHEN rate IS DISTINCT FROM prev_rate OR season_id IS DISTINCT FROM prev_season_id
                        THEN 1 ELSE 0 END) OVER (PARTITION BY period_id ORDER BY day) AS run_no
        FROM lagged
    )
    SELECT EXTRACT(EPOCH FROM MAX(runs.day))::INT AS "timestamp",
           runs.season_id::INT,
           ts.season_name,
           runs.period_id::INT,
           tp.period_name,
           COALESCE(ROUND(runs.rate::NUMERIC, 4), 0.0)::FLOAT AS rate
    FROM runs
    JOIN tariff_dev_v2.tou_periods tp ON tp.period_id = runs.period_id
    JOIN tariff_dev_v2.tou_seasons ts ON ts.season_id = runs.season_id
    GROUP BY runs.period_id, runs.run_no, runs.season_id, runs.rate, tp.period_name, ts.season_name
    ORDER BY "timestamp";
$$;


--
-- TOC entry 3924 (class 1255 OID 181700731)
-- Name: get_utilised_capacity_charge_cost(integer, integer, integer[], integer, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.get_utilised_capacity_charge_cost(p_tariff_id integer, p_rate_class_id integer, p_attribute_value_ids integer[], p_notified_demand integer, p_subsystem_cuid text, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE("timestamp" integer, cost double precision, utilised_capacity double precision, max_demand double precision, subsys text)
    LANGUAGE sql STABLE
    AS $$
    WITH md AS (
        SELECT max(elem.value::NUMERIC) AS md
        FROM hyper."SystemStandardValueLog" sv
        CROSS JOIN LATERAL jsonb_array_elements(sv.extensions -> 'binned_30_kva') AS elem(value)
        WHERE sv.subsystem_cuid = p_subsystem_cuid
          AND sv."timestamp" BETWEEN p_start_date AND p_end_date
          AND sv.extensions -> 'binned_30_kva' IS NOT NULL
    ),
    uc AS (SELECT GREATEST(p_notified_demand, COALESCE(md.md, 0)) AS uc, md.md FROM md)
    SELECT EXTRACT(EPOCH FROM p_end_date)::INT,
           tariff_dev_v2.capacity_rate_cost(p_tariff_id, p_rate_class_id, p_attribute_value_ids, uc.uc, p_start_date, p_end_date)::FLOAT,
           ROUND(uc.uc, 2)::FLOAT, ROUND(uc.md, 2)::FLOAT, p_subsystem_cuid
    FROM uc
    WHERE EXISTS (SELECT 1 FROM tariff_dev_v2.rates r
                  WHERE r.tariff_id = p_tariff_id AND r.rate_class_id = p_rate_class_id
                    AND r.valid_from <= tariff_dev_v2.local_date(p_end_date)
                    AND COALESCE(r.valid_to, 'infinity'::DATE) >= tariff_dev_v2.local_date(p_start_date));
$$;


--
-- TOC entry 3752 (class 1255 OID 181700692)
-- Name: local_date(timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.local_date(p_ts timestamp without time zone) RETURNS date
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT (p_ts AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg')::DATE;
$$;


--
-- TOC entry 3213 (class 1255 OID 181700693)
-- Name: local_months_before(timestamp without time zone, integer); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.local_months_before(p_ts timestamp without time zone, p_k integer) RETURNS timestamp without time zone
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT ((p_ts AT TIME ZONE 'UTC' AT TIME ZONE 'Africa/Johannesburg') - make_interval(months => p_k))
           AT TIME ZONE 'Africa/Johannesburg' AT TIME ZONE 'UTC';
$$;


--
-- TOC entry 3095 (class 1255 OID 181700725)
-- Name: mec_months(text, numeric, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.mec_months(p_system_cuid text, p_mec numeric, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE(k integer, max_export numeric, is_event boolean, in_deadband boolean, free boolean)
    LANGUAGE sql STABLE
    AS $$
    WITH months AS (
        SELECT m.k,
               CASE WHEN m.k = 0 THEN p_start_date ELSE tariff_dev_v2.local_months_before(p_start_date, m.k) END        AS m_start,
               CASE WHEN m.k = 0 THEN p_end_date
                    ELSE tariff_dev_v2.local_months_before(p_start_date, m.k - 1) - INTERVAL '1 millisecond' END      AS m_end
        FROM generate_series(0, 35) m(k)
    ),
    hourly AS (
        SELECT sv."timestamp" AS ts, sum(sv.grid_export_kwh)::NUMERIC AS kw
        FROM hyper."SystemStandardValueLog" sv
        WHERE sv.system_cuid = p_system_cuid
          AND sv."timestamp" BETWEEN p_start_date - INTERVAL '35 months' AND p_end_date
          AND sv.grid_export_kwh IS NOT NULL
        GROUP BY sv."timestamp"
    ),
    mx AS (
        SELECT m.k, max(h.kw) AS mx
        FROM months m JOIN hourly h ON h.ts BETWEEN m.m_start AND m.m_end
        GROUP BY m.k
    )
    SELECT e.k, e.max_value, e.is_event, e.in_deadband, e.free
    FROM tariff_dev_v2.exceedance_months(
             (SELECT array_agg(mx.mx ORDER BY m.k) FROM months m LEFT JOIN mx ON mx.k = m.k), p_mec) e
    ORDER BY e.k;
$$;


--
-- TOC entry 2717 (class 1255 OID 181700702)
-- Name: nmd_months(text, numeric, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.nmd_months(p_subsystem_cuid text, p_notified_demand numeric, p_start_date timestamp without time zone, p_end_date timestamp without time zone) RETURNS TABLE(k integer, max_demand numeric, is_event boolean, in_deadband boolean, deadband_exempt boolean)
    LANGUAGE sql STABLE
    AS $$
    WITH months AS (
        SELECT m.k,
               CASE WHEN m.k = 0 THEN p_start_date ELSE tariff_dev_v2.local_months_before(p_start_date, m.k) END        AS m_start,
               CASE WHEN m.k = 0 THEN p_end_date
                    ELSE tariff_dev_v2.local_months_before(p_start_date, m.k - 1) - INTERVAL '1 millisecond' END      AS m_end
        FROM generate_series(0, 35) m(k)
    ),
    md AS (
        SELECT m.k, max(elem.value::NUMERIC) AS md
        FROM months m
        JOIN hyper."SystemStandardValueLog" sv
          ON  sv.subsystem_cuid = p_subsystem_cuid
          AND sv."timestamp" BETWEEN m.m_start AND m.m_end
          AND sv.extensions -> 'binned_30_kva' IS NOT NULL
        CROSS JOIN LATERAL jsonb_array_elements(sv.extensions -> 'binned_30_kva') AS elem(value)
        GROUP BY m.k
    )
    SELECT e.k, e.max_value, e.is_event, e.in_deadband, e.free
    FROM tariff_dev_v2.exceedance_months(
             (SELECT array_agg(md.md ORDER BY m.k) FROM months m LEFT JOIN md ON md.k = m.k), p_notified_demand) e
    ORDER BY e.k;
$$;


--
-- TOC entry 3631 (class 1255 OID 180043008)
-- Name: register_implementations(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.register_implementations() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_sig INT;
BEGIN
    DELETE FROM tariff_dev_v2.rate_class_operation_implementation;
    DELETE FROM tariff_dev_v2.implementation_signatures;

    -- Function families go here, one block each.
    --
    -- Parameter sources as in tariff_dev ("context", "interval_start", "interval_end", "override"),
    -- plus one new source for v2 (PROPOSED, pending the UI migration):
    --   "attribute_value_ids": the system's selected attribute_value_ids for this rate class, as an
    --   integer array (empty / null when the rate class has no attributes). Replaces one
    --   "attribute" parameter per attribute carrying text.

    -- ---------------------------------------------------------------------------------------------
    -- TOU cost / energy by period, from hourly std-val data.
    -- eskom_tou: checked against tariff_dev.get_eskom_tou_period_cost_from_std_val_hourly_cost_energy
    -- by compare/eskom_tou.sql (2026-11-14, identical).
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_tou_period_cost_from_std_val_hourly',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1, "source": "context", "context": "system_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_period_id",           "type": "integer",   "order": 4, "source": "override"},
                 {"name": "p_std_val_column",      "type": "text",      "order": 5, "source": "context", "context": "std_val_column"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 8, "source": "attribute_value_ids"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Hourly TOU cost and energy from std-val data, by period (override 0 = all)', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, 'TOU ' || op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key IN ('eskom_tou',
                          'stellenbosch_tou_export',  -- export energy (the UI's std_val_column: grid_export_kwh); compare/municipal_charges.sql
                          'stellenbosch_tou_import', -- import energy of the TOU tariffs (grid_import_kwh; 20261120160000)
                          'overstrand_tou',      -- import energy (grid_import_kwh); Eskom holiday scheme on its links
                          'tshwane_tou',         -- import energy; Eskom TOU hours and actual weekday assumed (20261119120000)
                          'city_power_tou',      -- import energy; City Power TOU hours, holidays as Saturday (20261119140000)
                          'city_power_seasonal', -- import energy; one rate every hour of a season (pattern group 9)
                          -- municipal TOU on the Eskom TOU hours, actual weekday; sources on the rates (20261119200000)
                          'bergriver_tou',       -- import (Small Consumer, Bulk MV / LV) and export (SSEG credits)
                          'kouga_tou',           -- import
                          'tzaneen_tou',         -- import; rates unverified (see the rate descriptions)
                          'mining_seasonal')    -- import; one rate every hour of a season (Seasonal Flat, 20261119220000)
      AND op.operation_key IN ('tou_cost_total', 'tou_cost_peak', 'tou_cost_standard', 'tou_cost_off_peak',
                               'tou_energy_total', 'tou_energy_peak', 'tou_energy_standard', 'tou_energy_off_peak');

    -- ---------------------------------------------------------------------------------------------
    -- TOU rates in force over an interval (rate_info).
    -- eskom_tou: checked against tariff_dev.get_eskom_tou_rates_for_interval by compare/eskom_tou.sql
    -- (2026-11-14, identical).
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_tou_rates_for_interval',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 4, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 5, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "None", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "season_id", "type": "int"},
                 {"name": "season_name", "type": "text"}, {"name": "period_id", "type": "int"},
                 {"name": "period_name", "type": "text"}, {"name": "rate", "type": "float"}]},
              "needs_subsys": false}',
            'TOU rates per season and period over an interval', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, 'TOU rate_info'
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key IN ('eskom_tou', 'stellenbosch_tou_export', 'stellenbosch_tou_import', 'overstrand_tou', 'tshwane_tou', 'tshwane_tou_demand_charge',
                          'city_power_tou', 'city_power_seasonal', 'bergriver_tou', 'kouga_tou', 'tzaneen_tou',
                          'mining_seasonal',
                          'distribution_net_demand_charge_kva',   -- R/kVA/m per season x (Peak, Standard)
                          'reactive_energy_charge_pk_std')        -- c/kvarh per season x (Peak, Standard)
      AND op.operation_key = 'rate_info';

    -- ---------------------------------------------------------------------------------------------
    -- Non-TOU charges. Checked by compare/eskom_nontou.sql (2026-11-14): identical to tariff_dev
    -- except rate shown at 4 dp, and per-kWh rate validity on the local date (see the functions).
    -- (rate_key, operation_key) pairs, so each rate class keeps the operation key the app uses.
    -- ---------------------------------------------------------------------------------------------

    -- per-kWh energy charges on hourly std-val data
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_energy_charge_cost_from_std_val_hourly',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1, "source": "context", "context": "system_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_std_val_column",      "type": "text",      "order": 4, "source": "context", "context": "std_val_column"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 7, "source": "attribute_value_ids"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Per-kWh charge on hourly std-val energy', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM (VALUES ('legacy_charge', 'legacy_charge'),
                 ('ancillary_service_charge', 'ancillary_service_charge'),
                 ('distribution_net_demand_charge', 'distribution_network_demand_charge'),
                 -- Megaflex: c/kWh on the total active energy at the POD (compare/energy_charge.sql)
                 ('electrification_rural_subsidy_charge', 'electrification_rural_subsidy_charge'),
                 ('affordability_subsidy_charge', 'affordability_subsidy_charge'),
                 -- municipal c/kWh energy charge (Stellenbosch IND; std_val_column grid_import_kwh)
                 ('energy_charge', 'energy_charge'),
                 -- City Power: c/kWh on all energy consumed (grid_import_kwh)
                 ('network_surcharge', 'network_surcharge'),
                 -- c/kWh credit on energy exported (std_val_column grid_export_kwh); the cost is the credit
                 ('export_credit', 'export_credit'),
                 -- flat c/kWh with a per-site attribute: Drakenstein ELB100 energy (grid import), CANDI Solar PV
                 -- internal rates (the UI's std_val_column for the PV energy)
                 ('generic_flat', 'energy_charge')) m(rate_key, operation_key)
    JOIN tariff_dev_v2.rate_classes rc ON rc.rate_key = m.rate_key
    JOIN tariff_dev_v2.rate_operations op ON op.operation_key = m.operation_key;

    -- fixed charges per day
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_daily_charge_cost',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 4, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 5, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "rate", "type": "float"}]},
              "needs_subsys": false}',
            'Fixed charge per day', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM (VALUES ('service_charge', 'service_charge'),
                 ('admin_charge', 'admin_charge')) m(rate_key, operation_key)
    JOIN tariff_dev_v2.rate_classes rc ON rc.rate_key = m.rate_key
    JOIN tariff_dev_v2.rate_operations op ON op.operation_key = m.operation_key;

    -- R/kVA/month capacity charges on annual utilised capacity
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_capacity_charge_cost_from_auc',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 4, "source": "context", "context": "notified_demand"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 5, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "auc", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Capacity charge on annual utilised capacity, prorated across rate changes', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM (VALUES ('generation_capacity_charge', 'generation_capacity_charge'),
                 ('net_capacity_charge', 'network_capacity_charge_charge'),
                 -- Megaflex: the Transmission network charge, the Distribution network capacity charge
                 -- and the urban low voltage subsidy charge, also on AUC (compare/capacity_charge.sql)
                 ('transmission_network_charge', 'network_capacity_charge_charge'),
                 ('distribution_net_capacity_charge', 'network_capacity_charge_charge'),
                 ('urban_lv_subsidy_charge', 'network_capacity_charge_charge')) m(rate_key, operation_key)
    JOIN tariff_dev_v2.rate_classes rc ON rc.rate_key = m.rate_key
    JOIN tariff_dev_v2.rate_operations op ON op.operation_key = m.operation_key;

    -- rate_info: rate periods across the interval
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_rate_eras_for_interval',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 4, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 5, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "None", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "rate", "type": "float"}]},
              "needs_subsys": false}',
            'Non-TOU rates over an interval, one row per run of equal rates', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, 'rate_info'
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key IN ('legacy_charge', 'ancillary_service_charge', 'distribution_net_demand_charge',
                          'service_charge', 'admin_charge',
                          'electrification_rural_subsidy_charge', 'affordability_subsidy_charge', 'energy_charge',
                          'network_surcharge', 'export_credit', 'generic_flat')
      AND op.operation_key = 'rate_info';

    -- excess network capacity charge (NMD exceedance)
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_excess_network_capacity_charge_cost',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 4, "source": "context", "context": "notified_demand"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 5, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "max_demand", "type": "float"}, {"name": "excess_kva", "type": "float"},
                 {"name": "event_number", "type": "int"}, {"name": "deadband_exempt", "type": "boolean"},
                 {"name": "rate", "type": "float"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Excess network capacity charge: MD above NMD x rate x event number (rolling 12 months, 5% deadband)', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    -- Megaflex / Megaflex Gen and Ruraflex (compare/excess_network_capacity.sql)
    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'excess_net_capacity_charge' AND op.operation_key = 'excess_network_capacity_charge';

    -- Megaflex Gen network charge top-ups: the generator network charge on MEC vs the load network
    -- charges, "the higher of" (items 8 and 9); compare/network_charge_topup.sql
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_network_charge_topup_dx_generators',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1,  "source": "context", "context": "system_cuid"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 2,  "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 3,  "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 4,  "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 5,  "source": "attribute_value_ids"},
                 {"name": "p_mec",                 "type": "numeric",   "order": 6,  "source": "context", "context": "maximum_export_capacity"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 7,  "source": "context", "context": "notified_demand"},
                 {"name": "p_std_val_column",      "type": "text",      "order": 8,  "source": "context", "context": "std_val_column"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 9,  "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 10, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "generator_charge", "type": "float"}, {"name": "losses_rebate", "type": "float"},
                 {"name": "generator_side", "type": "float"}, {"name": "load_side", "type": "float"},
                 {"name": "transmission_network", "type": "float"}, {"name": "distribution_capacity", "type": "float"},
                 {"name": "distribution_demand", "type": "float"}, {"name": "mec", "type": "float"},
                 {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Megaflex Gen (Distribution connected): max(0, MEC x Dx gen rate less losses rebate - Tx + Dx capacity + Dx demand load charges)', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'dx_network_capacity_charge_generators' AND op.operation_key = 'network_charge_generators_topup';

    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_network_charge_topup_tx_generators',
            '{"parameters": [
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 1, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 4, "source": "attribute_value_ids"},
                 {"name": "p_mec",                 "type": "numeric",   "order": 5, "source": "context", "context": "maximum_export_capacity"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 6, "source": "context", "context": "notified_demand"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 7, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 8, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "generator_side", "type": "float"}, {"name": "load_side", "type": "float"},
                 {"name": "mec", "type": "float"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Megaflex Gen (Transmission connected): max(0, MEC x Tx gen rate - Tx network load charge)', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'tx_network_charge_generators' AND op.operation_key = 'network_charge_generators_topup';

    -- Megaflex Gen excess MEC charge (mirrors the NMD rules until the MEC rules are published);
    -- compare/excess_mec.sql
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_excess_mec_charge_cost',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1, "source": "context", "context": "system_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 4, "source": "attribute_value_ids"},
                 {"name": "p_mec",                 "type": "numeric",   "order": 5, "source": "context", "context": "maximum_export_capacity"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "max_export", "type": "float"}, {"name": "excess_kw", "type": "float"},
                 {"name": "event_number", "type": "int"}, {"name": "deadband_exempt", "type": "boolean"},
                 {"name": "mec", "type": "float"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": false}',
            'Excess MEC charge: max hourly export above MEC x rate x event number (NMD-rule deadband)', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key IN ('excess_mec_charge_tx_generators', 'excess_mec_charge_dx_generators') AND op.operation_key = 'excess_mec_charge';

    -- Municipal monthly charges (Stellenbosch); compare/municipal_charges.sql
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_monthly_charge_cost',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 4, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 5, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "rate", "type": "float"}]},
              "needs_subsys": false}',
            'Fixed R/month charge for a billing month, prorated by days across a rate change', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM (VALUES ('fixed_monthly_charge', 'fixed_monthly_charge'),
                 ('meter_reading_charge', 'meter_reading_charge'),
                 ('monthly_capacity_charge', 'monthly_capacity_charge')) m(rate_key, operation_key)
    JOIN tariff_dev_v2.rate_classes rc ON rc.rate_key = m.rate_key
    JOIN tariff_dev_v2.rate_operations op ON op.operation_key = m.operation_key;

    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_nmd_charge_cost',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 4, "source": "context", "context": "notified_demand"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "nmd", "type": "float"}]},
              "needs_subsys": false}',
            'Municipal NMD charge: NMD x R/kVA/month, prorated by days across a rate change', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'nmd_charge' AND op.operation_key = 'nmd_charge';

    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_nmd_exceedance_surcharge_municipal',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 4, "source": "context", "context": "notified_demand"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 5, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "max_demand", "type": "float"}, {"name": "occasion", "type": "int"},
                 {"name": "surcharge_pct", "type": "int"}, {"name": "nmd_charge", "type": "float"},
                 {"name": "disconnection_risk", "type": "boolean"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Municipal NMD exceedance surcharge: 10/20/30% of the NMD charge on the 2nd/3rd/4th+ exceedance in the financial year', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'nmd_exceedance_surcharge_stellenbosch' AND op.operation_key = 'nmd_exceedance_surcharge';

    -- Overstrand: utilised capacity (network demand) charge and its NMD exceedance rule;
    -- compare/municipal_charges.sql
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_utilised_capacity_charge_cost',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 4, "source": "context", "context": "notified_demand"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 5, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "utilised_capacity", "type": "float"}, {"name": "max_demand", "type": "float"},
                 {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Utilised capacity charge: greatest(NMD, month peak 30-minute kVA) x R/kVA/month', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'utilised_capacity_charge' AND op.operation_key = 'utilised_capacity_charge';

    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_nmd_exceedance_charge_overstrand',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_notified_demand",     "type": "integer",   "order": 4, "source": "context", "context": "notified_demand"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 5, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "max_demand", "type": "float"}, {"name": "excess_kva", "type": "float"},
                 {"name": "warning", "type": "boolean"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Overstrand NMD exceedance: warning after 12 clear months, else excess kVA x R/kVA', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'nmd_exceedance_charge_overstrand' AND op.operation_key = 'nmd_exceedance_charge';

    -- rate_info: rate in force at the interval end
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_rate_at_interval_end',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 4, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 5, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "None", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "rate", "type": "float"}]},
              "needs_subsys": false}',
            'Non-TOU rate in force on the last day of the interval', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, 'rate_info'
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key IN ('generation_capacity_charge', 'net_capacity_charge', 'transmission_network_charge',
                          'distribution_net_capacity_charge', 'urban_lv_subsidy_charge', 'excess_net_capacity_charge',
                          'tx_network_charge_generators', 'dx_network_capacity_charge_generators',
                          'excess_mec_charge_tx_generators', 'excess_mec_charge_dx_generators',
                          'fixed_monthly_charge', 'meter_reading_charge', 'nmd_charge', 'demand_charge',
                          'nmd_exceedance_surcharge_stellenbosch', 'utilised_capacity_charge', 'nmd_exceedance_charge_overstrand',
                          'tshwane_demand_charge', 'city_power_demand_charge', 'monthly_capacity_charge')
      AND op.operation_key = 'rate_info';

    -- ---------------------------------------------------------------------------------------------
    -- Reactive energy on excess kvarh (> 30% of kWh), billing-period register totals, by season.
    -- No tariff_dev function; checked by compare/reactive_energy.sql against an independent calculation.
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_reactive_energy_charge_cost',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_entity_cuid",         "type": "text",      "order": 4, "source": "context", "context": "pod_entity_cuid"},
                 {"name": "p_kwh_parameter_id",    "type": "text",      "order": 5, "source": "context", "context": "pod_kwh_parameter_id"},
                 {"name": "p_kvarh_parameter_id",  "type": "text",      "order": 6, "source": "context", "context": "pod_kvarh_parameter_id"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 7, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 8, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "kvarh", "type": "float"}, {"name": "kwh", "type": "float"},
                 {"name": "excess_kvarh", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "season_id", "type": "int"}]},
              "needs_subsys": false}',
            'Reactive energy charge on kvarh above 30% of kWh, billing-period totals', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'reactive_energy_charge' AND op.operation_key = 'reactive_energy_charge';

    -- ---------------------------------------------------------------------------------------------
    -- Generator losses charges (a rebate, negative cost), hourly from std-val export energy,
    -- dispatched on the WEPS reference rate class. attribute_value_ids carries the loss factors'
    -- attributes: TZ and VS (Distribution connected) or GZ (Transmission connected).
    -- No tariff_dev function; checked by compare/losses_charge.sql against an independent calculation.
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_losses_charge_dx_generators_from_std_val_hourly',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1, "source": "context", "context": "system_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_std_val_column",      "type": "text",      "order": 4, "source": "context", "context": "std_val_column"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 7, "source": "attribute_value_ids"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "loss_term", "type": "float"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Distribution losses charge for Distribution connected generators (rebate, negative): kWh x WEPS x (DLF x TLF - 1)', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    -- Not dispatched as a bill line of its own: on Megaflex Gen the distribution losses charge only
    -- rebates the generator network charge inside get_network_charge_topup_dx_generators (item 9).

    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_losses_charge_tx_generators_from_std_val_hourly',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1, "source": "context", "context": "system_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_std_val_column",      "type": "text",      "order": 4, "source": "context", "context": "std_val_column"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 7, "source": "attribute_value_ids"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "loss_term", "type": "float"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Transmission losses charge for Transmission connected generators (rebate, negative): kWh x WEPS x (GLF - 1) / GLF', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'weps_energy_rate_excl_losses' AND op.operation_key = 'losses_charge_tx_generators';

    -- ---------------------------------------------------------------------------------------------
    -- R/kVA/month charge on chargeable demand (highest 30-minute kVA in the hours that have a rate:
    -- Megaflex peak + standard), prorated across rate changes. Same operation key as the c/kWh
    -- network demand charge: the rate class decides which implementation runs.
    -- No tariff_dev function; checked by compare/demand_charge.sql against an independent calculation.
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_demand_charge_cost_from_binned_kva',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 4, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "demand", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "demand_at", "type": "int"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'Demand charge on the highest 30-minute kVA in chargeable hours, prorated across rate changes', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'distribution_net_demand_charge_kva' AND op.operation_key = 'distribution_network_demand_charge';

    -- municipal R/kVA maximum demand charge (Flat link: every hour chargeable); compare/municipal_charges.sql
    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'demand_charge' AND op.operation_key = 'maximum_demand_charge';

    -- Tshwane demand charges, with the tariff's minimum demand (minimum_demand_kva);
    -- compare/municipal_charges.sql
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_demand_charge_cost_with_minimum',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 4, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "demand", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "demand_at", "type": "int"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'R/kVA demand charge on the chargeable hours, at least the tariff minimum demand', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key IN ('tshwane_demand_charge', 'tshwane_tou_demand_charge') AND op.operation_key = 'maximum_demand_charge';

    -- City Power: demand charge with the greater of 70 kVA and 80% of the average of the three
    -- highest demands of the preceding 12 months as minimum; compare/municipal_charges.sql
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_demand_charge_cost_city_power',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_subsystem_cuid",      "type": "text",      "order": 4, "source": "context", "context": "subsystem_cuid"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 5, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 6, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "demand", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "demand_at", "type": "int"}, {"name": "subsys", "type": "text"}]},
              "needs_subsys": true}',
            'City Power R/kVA demand charge: at least the greater of the minimum demand and 80% of the average of the 3 highest demands of the preceding 12 months', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'city_power_demand_charge' AND op.operation_key = 'maximum_demand_charge';

    -- ---------------------------------------------------------------------------------------------
    -- Reactive energy on excess kvarh (> 30% of kWh) per 30-minute period, in the periods that have a
    -- rate (Megaflex: peak + standard; low-season rate 0). Same operation key as the Ruraflex
    -- billing-total version: the rate class decides which implementation runs.
    -- No tariff_dev function; checked by compare/reactive_energy_30min.sql against an independent calculation.
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_reactive_energy_charge_cost_30min',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_entity_cuid",         "type": "text",      "order": 4, "source": "context", "context": "pod_entity_cuid"},
                 {"name": "p_kwh_parameter_id",    "type": "text",      "order": 5, "source": "context", "context": "pod_kwh_parameter_id"},
                 {"name": "p_kvarh_parameter_id",  "type": "text",      "order": 6, "source": "context", "context": "pod_kvarh_parameter_id"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 7, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 8, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "none", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "kvarh", "type": "float"}, {"name": "kwh", "type": "float"},
                 {"name": "excess_kvarh", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "season_id", "type": "int"}, {"name": "periods", "type": "int"},
                 {"name": "missing_periods", "type": "int"}]},
              "needs_subsys": false}',
            'Reactive energy charge on kvarh above 30% of kWh per 30-minute period, in the periods with a rate', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_key = 'reactive_energy_charge_pk_std' AND op.operation_key = 'reactive_energy_charge';

    -- ---------------------------------------------------------------------------------------------
    -- Block (inclining kWh) charges: block limits per dwelling unit per month x the site's dwelling
    -- units x days / 30.4375 (City Power / CoJ). dwelling_units is site metadata the portal passes,
    -- as notified_demand. Checked by compare/block_energy.sql (independent calculation and the South
    -- Hills bill, 293 units: R160,947.03).
    -- ---------------------------------------------------------------------------------------------
    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_block_energy_cost_from_std_val_hourly',
            '{"parameters": [
                 {"name": "p_system_cuid",         "type": "text",      "order": 1, "source": "context", "context": "system_cuid"},
                 {"name": "p_tariff_id",           "type": "integer",   "order": 2, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 3, "source": "context", "context": "rate_class_id"},
                 {"name": "p_std_val_column",      "type": "text",      "order": 4, "source": "context", "context": "std_val_column"},
                 {"name": "p_dwelling_units",      "type": "integer",   "order": 5, "source": "context", "context": "dwelling_units"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 6, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 7, "source": "interval_end"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 8, "source": "attribute_value_ids"}],
              "returns": {"type": "table", "aggregation": "sum", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"},
                 {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"},
                 {"name": "block_from", "type": "float"}]},
              "needs_subsys": false}',
            'Inclining-block c/kWh charge on the system''s hourly energy, block limits per dwelling unit x units x days / 30.4375', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, op.operation_key
    FROM tariff_dev_v2.rate_classes rc
    JOIN (VALUES ('block_energy_charge', 'energy_charge'),
                 ('network_surcharge_residential', 'network_surcharge')) m(rate_key, operation_key) ON m.rate_key = rc.rate_key
    JOIN tariff_dev_v2.rate_operations op ON op.operation_key = m.operation_key;

    INSERT INTO tariff_dev_v2.implementation_signatures (function_name, signature, description, valid_from)
    VALUES ('tariff_dev_v2.get_block_rates_for_interval',
            '{"parameters": [
                 {"name": "p_tariff_id",           "type": "integer",   "order": 1, "source": "context", "context": "tariff_id"},
                 {"name": "p_rate_class_id",       "type": "integer",   "order": 2, "source": "context", "context": "rate_class_id"},
                 {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"},
                 {"name": "p_start_date",          "type": "timestamp", "order": 4, "source": "interval_start"},
                 {"name": "p_end_date",            "type": "timestamp", "order": 5, "source": "interval_end"}],
              "returns": {"type": "table", "aggregation": "None", "columns": [
                 {"name": "timestamp", "type": "int"}, {"name": "rate", "type": "float"},
                 {"name": "block_from", "type": "float"}, {"name": "season", "type": "text"}]},
              "needs_subsys": false}',
            'Block rates over an interval, one row per rate era (rate period x season) and block', '2020-01-01')
    RETURNING signature_id INTO v_sig;

    INSERT INTO tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description)
    SELECT rc.rate_class_id, op.operation_id, v_sig, 'rate_info'
    FROM tariff_dev_v2.rate_classes rc, tariff_dev_v2.rate_operations op
    WHERE rc.rate_type = 'block' AND op.operation_key = 'rate_info';
END
$$;


--
-- TOC entry 3913 (class 1255 OID 180042688)
-- Name: sorted_distinct_ids(integer[]); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.sorted_distinct_ids(p_ids integer[]) RETURNS integer[]
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}'::INT[]) FROM unnest(p_ids) AS x
$$;


--
-- TOC entry 3021 (class 1255 OID 180043258)
-- Name: trg_attribute_collection_values_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_attribute_collection_values_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_ids INT[] := array_remove(ARRAY[CASE WHEN TG_OP <> 'INSERT' THEN OLD.attribute_collection_id END,
                                      CASE WHEN TG_OP <> 'DELETE' THEN NEW.attribute_collection_id END], NULL);
BEGIN
    PERFORM tariff_dev_v2.assert_collections_consistent(v_ids);
    PERFORM tariff_dev_v2.assert_rates_match_attributes('{}', v_ids, '{}');
    RETURN NULL;
END
$$;


--
-- TOC entry 2632 (class 1255 OID 180043257)
-- Name: trg_attribute_collections_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_attribute_collections_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM tariff_dev_v2.assert_collections_consistent(ARRAY[NEW.attribute_collection_id]);
    PERFORM tariff_dev_v2.assert_rates_match_attributes('{}', ARRAY[NEW.attribute_collection_id], '{}');
    RETURN NULL;
END
$$;


--
-- TOC entry 2758 (class 1255 OID 180043256)
-- Name: trg_rate_class_attributes_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_rate_class_attributes_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM tariff_dev_v2.assert_rates_match_attributes(
        array_remove(ARRAY[CASE WHEN TG_OP <> 'INSERT' THEN OLD.rate_class_id END,
                           CASE WHEN TG_OP <> 'DELETE' THEN NEW.rate_class_id END], NULL),
        '{}', '{}');
    RETURN NULL;
END
$$;


--
-- TOC entry 2362 (class 1255 OID 180043255)
-- Name: trg_rates_attribute_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_rates_attribute_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM tariff_dev_v2.assert_rates_match_attributes('{}', '{}', ARRAY[NEW.rate_id]);
    RETURN NULL;
END
$$;


--
-- TOC entry 2737 (class 1255 OID 181673765)
-- Name: trg_rates_block_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_rates_block_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.block_from <> 0 AND (SELECT rate_type FROM tariff_dev_v2.rate_classes WHERE rate_class_id = NEW.rate_class_id)
                               IS DISTINCT FROM 'block' THEN
        RAISE EXCEPTION 'rate %: block_from % in rate class %, which is not a block class (rate_type ''block'')',
            NEW.rate_id, NEW.block_from, NEW.rate_class_id;
    END IF;
    RETURN NULL;
END
$$;


--
-- TOC entry 2840 (class 1255 OID 180043613)
-- Name: trg_rates_window_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_rates_window_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM tariff_dev_v2.assert_rates_within_windows('{}', '{}', ARRAY[NEW.rate_id]);
    RETURN NULL;
END
$$;


--
-- TOC entry 3609 (class 1255 OID 180043614)
-- Name: trg_tariff_rate_classes_window_check(); Type: FUNCTION; Schema: tariff_dev_v2; Owner: -
--

CREATE FUNCTION tariff_dev_v2.trg_tariff_rate_classes_window_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM tariff_dev_v2.assert_rates_within_windows(ARRAY[OLD.tariff_id], ARRAY[OLD.rate_class_id], '{}');
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM tariff_dev_v2.assert_rates_within_windows(ARRAY[NEW.tariff_id], ARRAY[NEW.rate_class_id], '{}');
    END IF;
    RETURN NULL;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 2218 (class 1259 OID 180042702)
-- Name: attribute_collection_values; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.attribute_collection_values (
    attribute_collection_id integer NOT NULL,
    attribute_id integer NOT NULL,
    attribute_value_id integer NOT NULL
);


--
-- TOC entry 2217 (class 1259 OID 180042690)
-- Name: attribute_collections; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.attribute_collections (
    attribute_collection_id integer NOT NULL,
    attribute_value_ids integer[] NOT NULL,
    CONSTRAINT attribute_collections_canonical CHECK (((array_position(attribute_value_ids, NULL::integer) IS NULL) AND (attribute_value_ids = tariff_dev_v2.sorted_distinct_ids(attribute_value_ids))))
);


--
-- TOC entry 12000 (class 0 OID 0)
-- Dependencies: 2217
-- Name: TABLE attribute_collections; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON TABLE tariff_dev_v2.attribute_collections IS 'A set of attribute values that selects a rate. Id 0 = no attributes. attribute_value_ids is sorted and distinct; attribute_collection_values holds the same set as rows.';


--
-- TOC entry 2216 (class 1259 OID 180042689)
-- Name: attribute_collections_attribute_collection_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.attribute_collections ALTER COLUMN attribute_collection_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.attribute_collections_attribute_collection_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2214 (class 1259 OID 180042652)
-- Name: attribute_values; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.attribute_values (
    attribute_value_id integer NOT NULL,
    attribute_id integer NOT NULL,
    value text NOT NULL
);


--
-- TOC entry 2212 (class 1259 OID 180042637)
-- Name: attributes; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.attributes (
    attribute_id integer NOT NULL,
    attribute_code text NOT NULL,
    attribute_column text NOT NULL,
    ui_label text,
    ui_order integer,
    description text
);


--
-- TOC entry 2209 (class 1259 OID 180042602)
-- Name: rate_classes; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rate_classes (
    rate_class_id integer NOT NULL,
    rate_key character varying(50) NOT NULL,
    class_code text NOT NULL,
    description text,
    cost_unit character varying(50) NOT NULL,
    rate_type character varying(50),
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


--
-- TOC entry 12001 (class 0 OID 0)
-- Dependencies: 2209
-- Name: COLUMN rate_classes.cost_unit; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON COLUMN tariff_dev_v2.rate_classes.cost_unit IS 'What the rate is multiplied by: kWh, kVA, kVA/month, kVArh, day, month, ... Monthly utilised capacity is not a unit: it picks the customer category for per-day charges. kWh/kVA = network demand charge, which depending on the tariff is charged on chargeable demand (kVA) or active energy (kWh); the dispatch signature decides which source feeds it.';


--
-- TOC entry 2233 (class 1259 OID 180042872)
-- Name: rates; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rates (
    rate_id bigint NOT NULL,
    tariff_id integer NOT NULL,
    rate_class_id integer NOT NULL,
    pattern_class_id integer NOT NULL,
    attribute_collection_id integer DEFAULT 0 NOT NULL,
    season_id integer NOT NULL,
    period_id integer NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    rate numeric NOT NULL,
    tax_included boolean,
    description text,
    block_from numeric DEFAULT 0 NOT NULL,
    CONSTRAINT rates_block_from_nonnegative CHECK ((block_from >= (0)::numeric)),
    CONSTRAINT rates_valid_range CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)))
);


--
-- TOC entry 12002 (class 0 OID 0)
-- Dependencies: 2233
-- Name: TABLE rates; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON TABLE tariff_dev_v2.rates IS 'All rates. Key: tariff, rate class, pattern, attribute collection, season, period, validity. Non-TOU rates use the Flat pattern; attribute_collection_id 0 = no attributes.';


--
-- TOC entry 12003 (class 0 OID 0)
-- Dependencies: 2233
-- Name: COLUMN rates.rate; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON COLUMN tariff_dev_v2.rates.rate IS 'Cents per rate_classes.cost_unit, VAT excluded unless tax_included. Where cost_unit is ''factor'' (loss factors) it is a plain number.';


--
-- TOC entry 2240 (class 1259 OID 180042984)
-- Name: attribute_collections_overview; Type: VIEW; Schema: tariff_dev_v2; Owner: -
--

CREATE VIEW tariff_dev_v2.attribute_collections_overview AS
 SELECT c.attribute_collection_id,
    c.attribute_value_ids,
    COALESCE(string_agg(((a.attribute_code || '='::text) || av.value), ', '::text ORDER BY a.ui_order, a.attribute_code), '(none)'::text) AS attributes,
    ( SELECT count(*) AS count
           FROM tariff_dev_v2.rates r
          WHERE (r.attribute_collection_id = c.attribute_collection_id)) AS n_rates,
    ( SELECT string_agg(DISTINCT (rc.rate_key)::text, ', '::text) AS string_agg
           FROM (tariff_dev_v2.rates r
             JOIN tariff_dev_v2.rate_classes rc USING (rate_class_id))
          WHERE (r.attribute_collection_id = c.attribute_collection_id)) AS used_by_rate_classes
   FROM (((tariff_dev_v2.attribute_collections c
     LEFT JOIN tariff_dev_v2.attribute_collection_values acv ON ((acv.attribute_collection_id = c.attribute_collection_id)))
     LEFT JOIN tariff_dev_v2.attribute_values av ON ((av.attribute_value_id = acv.attribute_value_id)))
     LEFT JOIN tariff_dev_v2.attributes a ON ((a.attribute_id = acv.attribute_id)))
  GROUP BY c.attribute_collection_id, c.attribute_value_ids;


--
-- TOC entry 12004 (class 0 OID 0)
-- Dependencies: 2240
-- Name: VIEW attribute_collections_overview; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON VIEW tariff_dev_v2.attribute_collections_overview IS 'Browse: attribute collections spelled out, with the rate classes that use them.';


--
-- TOC entry 2213 (class 1259 OID 180042651)
-- Name: attribute_values_attribute_value_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.attribute_values ALTER COLUMN attribute_value_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.attribute_values_attribute_value_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2211 (class 1259 OID 180042636)
-- Name: attributes_attribute_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.attributes ALTER COLUMN attribute_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.attributes_attribute_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2204 (class 1259 OID 180042561)
-- Name: countries; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.countries (
    country_code character(2) NOT NULL,
    country_name text NOT NULL
);


--
-- TOC entry 2205 (class 1259 OID 180042570)
-- Name: currencies; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.currencies (
    currency_code character(3) NOT NULL,
    currency_name text NOT NULL,
    symbol text,
    minor_units integer
);


--
-- TOC entry 2237 (class 1259 OID 180042939)
-- Name: implementation_signatures; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.implementation_signatures (
    signature_id integer NOT NULL,
    function_name text NOT NULL,
    signature jsonb NOT NULL,
    description text,
    valid_from date,
    valid_to date
);


--
-- TOC entry 2238 (class 1259 OID 180042949)
-- Name: rate_class_operation_implementation; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rate_class_operation_implementation (
    rate_class_id integer NOT NULL,
    operation_id integer NOT NULL,
    signature_id integer NOT NULL,
    description text,
    valid_from date,
    valid_to date
);


--
-- TOC entry 2235 (class 1259 OID 180042926)
-- Name: rate_operations; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rate_operations (
    operation_id integer NOT NULL,
    operation_key character varying(50) NOT NULL,
    description text,
    parameter_overrides jsonb,
    return_type text,
    created_at timestamp without time zone DEFAULT now()
);


--
-- TOC entry 2241 (class 1259 OID 180042989)
-- Name: dispatch_overview; Type: VIEW; Schema: tariff_dev_v2; Owner: -
--

CREATE VIEW tariff_dev_v2.dispatch_overview AS
 SELECT rc.rate_class_id,
    rc.rate_key,
    rc.class_code,
    op.operation_key,
    s.function_name,
    s.description,
    ( SELECT string_agg(((((prm.value ->> 'name'::text) || ' <- '::text) || (prm.value ->> 'source'::text)) || COALESCE((':'::text || (prm.value ->> 'context'::text)), ''::text)), ', '::text ORDER BY ((prm.value ->> 'order'::text))::integer) AS string_agg
           FROM jsonb_array_elements((s.signature -> 'parameters'::text)) prm(value)) AS parameters,
    s.signature_id
   FROM (((tariff_dev_v2.rate_class_operation_implementation i
     JOIN tariff_dev_v2.rate_classes rc ON ((rc.rate_class_id = i.rate_class_id)))
     JOIN tariff_dev_v2.rate_operations op ON ((op.operation_id = i.operation_id)))
     JOIN tariff_dev_v2.implementation_signatures s ON ((s.signature_id = i.signature_id)));


--
-- TOC entry 12005 (class 0 OID 0)
-- Dependencies: 2241
-- Name: VIEW dispatch_overview; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON VIEW tariff_dev_v2.dispatch_overview IS 'Browse: the v2 function each rate class runs for each operation, and its parameter sources.';


--
-- TOC entry 2247 (class 1259 OID 180053875)
-- Name: holiday_scheme_days; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.holiday_scheme_days (
    holiday_scheme_id integer NOT NULL,
    holiday_date date NOT NULL,
    treated_dow integer NOT NULL,
    CONSTRAINT holiday_scheme_days_treated_dow_check CHECK (((treated_dow >= 0) AND (treated_dow <= 6)))
);


--
-- TOC entry 12006 (class 0 OID 0)
-- Dependencies: 2247
-- Name: TABLE holiday_scheme_days; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON TABLE tariff_dev_v2.holiday_scheme_days IS 'The TOU day of the week (0 Sunday .. 6 Saturday) a holiday is treated as under a scheme. No row = actual weekday.';


--
-- TOC entry 2246 (class 1259 OID 180053863)
-- Name: holiday_schemes; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.holiday_schemes (
    holiday_scheme_id integer NOT NULL,
    scheme_key text NOT NULL,
    description text NOT NULL
);


--
-- TOC entry 12007 (class 0 OID 0)
-- Dependencies: 2246
-- Name: TABLE holiday_schemes; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON TABLE tariff_dev_v2.holiday_schemes IS 'How a group of tariffs treats public holidays for TOU. Linked from tariff_tou_pattern_link.holiday_scheme_id.';


--
-- TOC entry 2236 (class 1259 OID 180042938)
-- Name: implementation_signatures_signature_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.implementation_signatures ALTER COLUMN signature_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.implementation_signatures_signature_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2245 (class 1259 OID 180053853)
-- Name: public_holidays; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.public_holidays (
    holiday_date date NOT NULL,
    holiday_name text NOT NULL,
    source text NOT NULL
);


--
-- TOC entry 12008 (class 0 OID 0)
-- Dependencies: 2245
-- Name: TABLE public_holidays; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON TABLE tariff_dev_v2.public_holidays IS 'Gazetted public holidays (input outside the tariffs). TOU treatment per tariff is in holiday_scheme_days.';


--
-- TOC entry 2239 (class 1259 OID 180042974)
-- Name: rate_class_attribute_options; Type: VIEW; Schema: tariff_dev_v2; Owner: -
--

CREATE VIEW tariff_dev_v2.rate_class_attribute_options AS
 SELECT r.tariff_id,
    r.rate_class_id,
    r.attribute_collection_id,
    a.attribute_id,
    a.attribute_code,
    a.ui_label,
    a.ui_order,
    av.attribute_value_id,
    av.value,
    min(r.valid_from) AS valid_from,
        CASE
            WHEN bool_or((r.valid_to IS NULL)) THEN NULL::date
            ELSE max(r.valid_to)
        END AS valid_to
   FROM (((tariff_dev_v2.rates r
     JOIN tariff_dev_v2.attribute_collection_values acv ON ((acv.attribute_collection_id = r.attribute_collection_id)))
     JOIN tariff_dev_v2.attributes a ON ((a.attribute_id = acv.attribute_id)))
     JOIN tariff_dev_v2.attribute_values av ON ((av.attribute_value_id = acv.attribute_value_id)))
  GROUP BY r.tariff_id, r.rate_class_id, r.attribute_collection_id, a.attribute_id, a.attribute_code, a.ui_label, a.ui_order, av.attribute_value_id, av.value;


--
-- TOC entry 12009 (class 0 OID 0)
-- Dependencies: 2239
-- Name: VIEW rate_class_attribute_options; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON VIEW tariff_dev_v2.rate_class_attribute_options IS 'Attribute values the UI may offer per (tariff, rate class): only combinations that have rates. Selected attribute_value_ids go to attribute_collection_id(rate_class_id, ids).';


--
-- TOC entry 2215 (class 1259 OID 180042671)
-- Name: rate_class_attributes; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rate_class_attributes (
    rate_class_id integer NOT NULL,
    attribute_id integer NOT NULL
);


--
-- TOC entry 2223 (class 1259 OID 180042744)
-- Name: rate_class_tou_periods; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rate_class_tou_periods (
    rate_class_id integer NOT NULL,
    period_id integer NOT NULL,
    period_label text,
    sort_order smallint
);


--
-- TOC entry 2224 (class 1259 OID 180042763)
-- Name: rate_class_tou_seasons; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.rate_class_tou_seasons (
    rate_class_id integer NOT NULL,
    season_id integer NOT NULL,
    season_label text,
    sort_order smallint
);


--
-- TOC entry 2208 (class 1259 OID 180042601)
-- Name: rate_classes_rate_class_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.rate_classes ALTER COLUMN rate_class_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.rate_classes_rate_class_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2234 (class 1259 OID 180042925)
-- Name: rate_operations_operation_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.rate_operations ALTER COLUMN operation_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.rate_operations_operation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2207 (class 1259 OID 180042580)
-- Name: tariffs; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tariffs (
    tariff_id integer NOT NULL,
    tariff_name text NOT NULL,
    country_code character(2) NOT NULL,
    currency character(3) NOT NULL,
    valid_from date,
    valid_to date,
    description text
);


--
-- TOC entry 2226 (class 1259 OID 180042783)
-- Name: tou_patterns; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tou_patterns (
    pattern_class_id integer NOT NULL,
    pattern_name text NOT NULL,
    created_on date DEFAULT CURRENT_DATE NOT NULL,
    description text
);


--
-- TOC entry 2220 (class 1259 OID 180042721)
-- Name: tou_periods; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tou_periods (
    period_id integer NOT NULL,
    period_name text NOT NULL
);


--
-- TOC entry 2222 (class 1259 OID 180042733)
-- Name: tou_seasons; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tou_seasons (
    season_id integer NOT NULL,
    season_name text NOT NULL
);


--
-- TOC entry 2260 (class 1259 OID 181700744)
-- Name: rates_overview; Type: VIEW; Schema: tariff_dev_v2; Owner: -
--

CREATE VIEW tariff_dev_v2.rates_overview AS
 SELECT t.tariff_id,
    t.tariff_name,
    rc.rate_class_id,
    rc.rate_key,
    rc.class_code,
    rc.cost_unit,
    p.pattern_name,
    r.attribute_collection_id,
    COALESCE(ac.attributes, '(none)'::text) AS attributes,
    COALESCE(rcs.season_label, s.season_name) AS season,
    COALESCE(rcp.period_label, pe.period_name) AS period,
    r.valid_from,
    r.valid_to,
    r.rate AS rate_cents,
        CASE
            WHEN ((rc.cost_unit)::text = ANY (ARRAY[('factor'::character varying)::text, ('percent'::character varying)::text, ('kVA (quantity)'::character varying)::text])) THEN NULL::numeric
            ELSE round((r.rate / 100.0), 4)
        END AS rate_rand,
    r.tax_included,
    r.description,
    r.rate_id,
    r.block_from
   FROM ((((((((tariff_dev_v2.rates r
     JOIN tariff_dev_v2.tariffs t ON ((t.tariff_id = r.tariff_id)))
     JOIN tariff_dev_v2.rate_classes rc ON ((rc.rate_class_id = r.rate_class_id)))
     JOIN tariff_dev_v2.tou_patterns p ON ((p.pattern_class_id = r.pattern_class_id)))
     JOIN tariff_dev_v2.tou_seasons s ON ((s.season_id = r.season_id)))
     JOIN tariff_dev_v2.tou_periods pe ON ((pe.period_id = r.period_id)))
     LEFT JOIN tariff_dev_v2.rate_class_tou_seasons rcs ON (((rcs.rate_class_id = r.rate_class_id) AND (rcs.season_id = r.season_id))))
     LEFT JOIN tariff_dev_v2.rate_class_tou_periods rcp ON (((rcp.rate_class_id = r.rate_class_id) AND (rcp.period_id = r.period_id))))
     LEFT JOIN ( SELECT acv.attribute_collection_id,
            string_agg(((a.attribute_code || '='::text) || av.value), ', '::text ORDER BY a.ui_order, a.attribute_code) AS attributes
           FROM ((tariff_dev_v2.attribute_collection_values acv
             JOIN tariff_dev_v2.attribute_values av ON ((av.attribute_value_id = acv.attribute_value_id)))
             JOIN tariff_dev_v2.attributes a ON ((a.attribute_id = acv.attribute_id)))
          GROUP BY acv.attribute_collection_id) ac ON ((ac.attribute_collection_id = r.attribute_collection_id)));


--
-- TOC entry 2232 (class 1259 OID 180042871)
-- Name: rates_rate_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.rates ALTER COLUMN rate_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.rates_rate_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2242 (class 1259 OID 180043224)
-- Name: schema_migrations; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.schema_migrations (
    version character varying NOT NULL
);


--
-- TOC entry 2210 (class 1259 OID 180042617)
-- Name: tariff_rate_classes; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tariff_rate_classes (
    tariff_id integer NOT NULL,
    rate_class_id integer NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    CONSTRAINT tariff_rate_classes_valid_range CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)))
);


--
-- TOC entry 2231 (class 1259 OID 180042835)
-- Name: tariff_tou_pattern_link; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tariff_tou_pattern_link (
    link_id integer NOT NULL,
    tariff_id integer NOT NULL,
    rate_class_id integer NOT NULL,
    pattern_class_id integer NOT NULL,
    pattern_detail_id integer NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    holiday_scheme_id integer,
    CONSTRAINT tariff_tou_pattern_link_valid_range CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)))
);


--
-- TOC entry 12010 (class 0 OID 0)
-- Dependencies: 2231
-- Name: COLUMN tariff_tou_pattern_link.holiday_scheme_id; Type: COMMENT; Schema: tariff_dev_v2; Owner: -
--

COMMENT ON COLUMN tariff_dev_v2.tariff_tou_pattern_link.holiday_scheme_id IS 'Public holiday treatment for this link (holiday_scheme_days); NULL = holidays keep their actual weekday.';


--
-- TOC entry 2230 (class 1259 OID 180042834)
-- Name: tariff_tou_pattern_link_link_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.tariff_tou_pattern_link ALTER COLUMN link_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.tariff_tou_pattern_link_link_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2206 (class 1259 OID 180042579)
-- Name: tariffs_tariff_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.tariffs ALTER COLUMN tariff_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.tariffs_tariff_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2229 (class 1259 OID 180042805)
-- Name: tou_pattern_detail; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tou_pattern_detail (
    pattern_detail_id integer NOT NULL,
    season_id integer NOT NULL,
    period_id integer NOT NULL,
    month integer NOT NULL,
    dow integer NOT NULL,
    hour integer NOT NULL,
    CONSTRAINT tou_pattern_detail_dow_check CHECK (((dow >= 0) AND (dow <= 6))),
    CONSTRAINT tou_pattern_detail_hour_check CHECK (((hour >= 0) AND (hour <= 23))),
    CONSTRAINT tou_pattern_detail_month_check CHECK (((month >= 1) AND (month <= 12)))
);


--
-- TOC entry 2228 (class 1259 OID 180042797)
-- Name: tou_pattern_groups; Type: TABLE; Schema: tariff_dev_v2; Owner: -
--

CREATE TABLE tariff_dev_v2.tou_pattern_groups (
    pattern_detail_id integer NOT NULL,
    description text
);


--
-- TOC entry 2227 (class 1259 OID 180042796)
-- Name: tou_pattern_groups_pattern_detail_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.tou_pattern_groups ALTER COLUMN pattern_detail_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.tou_pattern_groups_pattern_detail_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2225 (class 1259 OID 180042782)
-- Name: tou_patterns_pattern_class_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.tou_patterns ALTER COLUMN pattern_class_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.tou_patterns_pattern_class_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2219 (class 1259 OID 180042720)
-- Name: tou_periods_period_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.tou_periods ALTER COLUMN period_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.tou_periods_period_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 2221 (class 1259 OID 180042732)
-- Name: tou_seasons_season_id_seq; Type: SEQUENCE; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE tariff_dev_v2.tou_seasons ALTER COLUMN season_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME tariff_dev_v2.tou_seasons_season_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 11967 (class 0 OID 180042702)
-- Dependencies: 2218
-- Data for Name: attribute_collection_values; Type: TABLE DATA; Schema: tariff_dev_v2; Owner: -
--

COPY tariff_dev_v2.attribute_collection_values (attribute_collection_id, attribute_id, attribute_value_id) FROM stdin;
1	1	1
1	2	5
2	1	1
2	2	6
3	1	2
3	2	5
4	1	2
4	2	6
5	1	3
5	2	5
6	1	3
6	2	6
7	1	4
7	2	5
8	1	4
8	2	6
9	2	5
10	2	6
11	3	10
12	3	11
13	3	12
16	4	18
17	4	19
18	4	20
19	4	21
20	4	22
21	3	23
25	1	2
25	2	7
26	1	2
26	2	8
33	1	4
33	2	9
32	1	4
32	2	8
24	1	1
24	2	9
28	1	3
28	2	7
30	1	3
30	2	9
29	1	3
29	2	8
36	2	9
23	1	1
23	2	8
35	2	8
27	1	2
27	2	9
31	1	4
31	2	7
34	2	7
22	1	1
22	2	7
41	5	25
44	5	28
43	5	27
39	1	3
46	5	30
40	1	4
37	1	1
38	1	2
42	5	26
45	5	29
\.

COPY tariff_dev_v2.attribute_collections (attribute_collection_id, attribute_value_ids) FROM stdin;
0	{}
1	{1,5}
2	{1,6}
3	{2,5}
4	{2,6}
5	{3,5}
6	{3,6}
7	{4,5}
8	{4,6}
9	{5}
10	{6}
11	{10}
12	{11}
13	{12}
16	{18}
17	{19}
18	{20}
19	{21}
20	{22}
21	{23}
22	{1,7}
23	{1,8}
24	{1,9}
25	{2,7}
26	{2,8}
27	{2,9}
28	{3,7}
29	{3,8}
30	{3,9}
31	{4,7}
32	{4,8}
33	{4,9}
34	{7}
35	{8}
36	{9}
37	{1}
38	{2}
39	{3}
40	{4}
41	{25}
42	{26}
43	{27}
44	{28}
45	{29}
46	{30}
\.

COPY tariff_dev_v2.attribute_values (attribute_value_id, attribute_id, value) FROM stdin;
1	1	300
2	1	600
3	1	900
4	1	+900
5	2	500
6	2	22kV
7	2	66kV
8	2	132kV
9	2	+132kV
10	3	MTHUBA
11	3	HUHLUWE
12	3	MBAZWAN
17	3	EXPORT
16	3	IMPORT
22	4	Key Customer
18	4	CC <= 100 kVA
19	4	100 kVA < CC <=500kVA
20	4	500 kVA < CC <=1MVA
21	4	1MVA < CC
23	3	100 kVA < Large Bulk Users
24	3	40 kVA < Bulk Users < 100 kVA 
15	3	generic
25	5	Cape
26	5	Karoo
27	5	Kwazulu-Natal
28	5	Vaal
29	5	Waterberg
30	5	Mpumalanga
\.

COPY tariff_dev_v2.attributes (attribute_id, attribute_code, attribute_column, ui_label, ui_order, description) FROM stdin;
1	TZ	transmission_zone	\N	\N	The ESKOM Transmission Zone
2	VS	voltage_of_supply	\N	\N	The Voltage of Supply of the Point of Connection
3	RC	rate_classifier	\N	\N	A code to classify different flat rates
4	CC	customer_category	\N	\N	Eskom customer categories based on connection sizing
5	GZ	generator_transmission_zone	\N	\N	The Eskom Transmission zone for generators
\.

COPY tariff_dev_v2.countries (country_code, country_name) FROM stdin;
ZA	South Africa
US	United States
GB	United Kingdom
DE	Germany
\.

COPY tariff_dev_v2.currencies (currency_code, currency_name, symbol, minor_units) FROM stdin;
ZAR	South African Rand	R	2
USD	US Dollar	$	2
EUR	Euro	€	2
\.

COPY tariff_dev_v2.holiday_scheme_days (holiday_scheme_id, holiday_date, treated_dow) FROM stdin;
1	2024-04-01	0
1	2024-04-27	6
1	2024-05-01	6
1	2024-06-16	0
1	2024-06-17	6
1	2024-08-09	6
1	2024-09-24	6
1	2024-12-16	6
1	2024-12-25	0
1	2024-12-26	0
1	2025-01-01	0
1	2025-03-21	6
1	2025-04-18	0
1	2025-04-21	0
1	2025-04-27	0
1	2025-04-28	6
1	2025-05-01	6
1	2025-06-16	6
1	2025-08-09	6
1	2025-09-24	6
1	2025-12-16	6
1	2025-12-25	0
1	2025-12-26	0
1	2026-01-01	0
1	2026-03-21	6
1	2026-04-03	0
1	2026-04-06	0
1	2026-04-27	6
1	2026-05-01	6
1	2026-06-16	6
1	2026-08-09	0
1	2026-08-10	6
1	2026-09-24	6
1	2026-12-16	6
1	2026-12-25	0
1	2026-12-26	0
1	2027-01-01	0
1	2027-03-21	0
1	2027-03-22	6
1	2027-03-26	0
1	2027-03-29	0
1	2027-04-27	6
1	2027-05-01	6
1	2027-06-16	6
2	2024-04-01	6
2	2024-04-27	6
2	2024-05-01	6
2	2024-06-16	6
2	2024-06-17	6
2	2024-08-09	6
2	2024-09-24	6
2	2024-12-16	6
2	2024-12-25	6
2	2024-12-26	6
2	2025-01-01	6
2	2025-03-21	6
2	2025-04-18	6
2	2025-04-21	6
2	2025-04-27	6
2	2025-04-28	6
2	2025-05-01	6
2	2025-06-16	6
2	2025-08-09	6
2	2025-09-24	6
2	2025-12-16	6
2	2025-12-25	6
2	2025-12-26	6
2	2026-01-01	6
2	2026-03-21	6
2	2026-04-03	6
2	2026-04-06	6
2	2026-04-27	6
2	2026-05-01	6
2	2026-06-16	6
2	2026-08-09	6
2	2026-08-10	6
2	2026-09-24	6
2	2026-12-16	6
2	2026-12-25	6
2	2026-12-26	6
2	2027-01-01	6
2	2027-03-21	6
2	2027-03-22	6
2	2027-03-26	6
2	2027-03-29	6
2	2027-04-27	6
2	2027-05-01	6
2	2027-06-16	6
\.

COPY tariff_dev_v2.holiday_schemes (holiday_scheme_id, scheme_key, description) FROM stdin;
1	eskom_megaflex	Eskom Megaflex, Megaflex Gen, Miniflex, Municflex and WEPS: New Year's Day, Good Friday, Family Day, Christmas Day and Day of Goodwill as a Sunday; other holidays as a Saturday, or a Sunday if they fall on one.
2	city_power	City Power Johannesburg: every public holiday as a Saturday (schedule of approved tariffs FY26/27, TOU periods).
\.

COPY tariff_dev_v2.implementation_signatures (signature_id, function_name, signature, description, valid_from, valid_to) FROM stdin;
517	tariff_dev_v2.get_losses_charge_dx_generators_from_std_val_hourly	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "loss_term", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "sum"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_std_val_column", "type": "text", "order": 4, "source": "context", "context": "std_val_column"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 7, "source": "attribute_value_ids"}], "needs_subsys": true}	Distribution losses charge for Distribution connected generators (rebate, negative): kWh x WEPS x (DLF x TLF - 1)	2020-01-01	\N
518	tariff_dev_v2.get_losses_charge_tx_generators_from_std_val_hourly	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "loss_term", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "sum"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_std_val_column", "type": "text", "order": 4, "source": "context", "context": "std_val_column"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 7, "source": "attribute_value_ids"}], "needs_subsys": true}	Transmission losses charge for Transmission connected generators (rebate, negative): kWh x WEPS x (GLF - 1) / GLF	2020-01-01	\N
519	tariff_dev_v2.get_demand_charge_cost_from_binned_kva	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "demand", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "demand_at", "type": "int"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_subsystem_cuid", "type": "text", "order": 4, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}], "needs_subsys": true}	Demand charge on the highest 30-minute kVA in chargeable hours, prorated across rate changes	2020-01-01	\N
520	tariff_dev_v2.get_demand_charge_cost_with_minimum	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "demand", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "demand_at", "type": "int"}, {"name": "subsys", "type": "text"}], "aggregation": "sum"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_subsystem_cuid", "type": "text", "order": 4, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}], "needs_subsys": true}	R/kVA demand charge on the chargeable hours, at least the tariff minimum demand	2020-01-01	\N
521	tariff_dev_v2.get_demand_charge_cost_city_power	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "demand", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "demand_at", "type": "int"}, {"name": "subsys", "type": "text"}], "aggregation": "sum"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_subsystem_cuid", "type": "text", "order": 4, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}], "needs_subsys": true}	City Power R/kVA demand charge: at least the greater of the minimum demand and 80% of the average of the 3 highest demands of the preceding 12 months	2020-01-01	\N
522	tariff_dev_v2.get_reactive_energy_charge_cost_30min	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "kvarh", "type": "float"}, {"name": "kwh", "type": "float"}, {"name": "excess_kvarh", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "season_id", "type": "int"}, {"name": "periods", "type": "int"}, {"name": "missing_periods", "type": "int"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_entity_cuid", "type": "text", "order": 4, "source": "context", "context": "pod_entity_cuid"}, {"name": "p_kwh_parameter_id", "type": "text", "order": 5, "source": "context", "context": "pod_kwh_parameter_id"}, {"name": "p_kvarh_parameter_id", "type": "text", "order": 6, "source": "context", "context": "pod_kvarh_parameter_id"}, {"name": "p_start_date", "type": "timestamp", "order": 7, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 8, "source": "interval_end"}], "needs_subsys": false}	Reactive energy charge on kvarh above 30% of kWh per 30-minute period, in the periods with a rate	2020-01-01	\N
500	tariff_dev_v2.get_tou_period_cost_from_std_val_hourly	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "sum"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_period_id", "type": "integer", "order": 4, "source": "override"}, {"name": "p_std_val_column", "type": "text", "order": 5, "source": "context", "context": "std_val_column"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 8, "source": "attribute_value_ids"}], "needs_subsys": true}	Hourly TOU cost and energy from std-val data, by period (override 0 = all)	2020-01-01	\N
501	tariff_dev_v2.get_tou_rates_for_interval	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "season_id", "type": "int"}, {"name": "season_name", "type": "text"}, {"name": "period_id", "type": "int"}, {"name": "period_name", "type": "text"}, {"name": "rate", "type": "float"}], "aggregation": "None"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_start_date", "type": "timestamp", "order": 4, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 5, "source": "interval_end"}], "needs_subsys": false}	TOU rates per season and period over an interval	2020-01-01	\N
502	tariff_dev_v2.get_energy_charge_cost_from_std_val_hourly	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "sum"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_std_val_column", "type": "text", "order": 4, "source": "context", "context": "std_val_column"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 7, "source": "attribute_value_ids"}], "needs_subsys": true}	Per-kWh charge on hourly std-val energy	2020-01-01	\N
503	tariff_dev_v2.get_daily_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "rate", "type": "float"}], "aggregation": "sum"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_start_date", "type": "timestamp", "order": 4, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 5, "source": "interval_end"}], "needs_subsys": false}	Fixed charge per day	2020-01-01	\N
504	tariff_dev_v2.get_capacity_charge_cost_from_auc	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "auc", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_notified_demand", "type": "integer", "order": 4, "source": "context", "context": "notified_demand"}, {"name": "p_subsystem_cuid", "type": "text", "order": 5, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}], "needs_subsys": true}	Capacity charge on annual utilised capacity, prorated across rate changes	2020-01-01	\N
505	tariff_dev_v2.get_rate_eras_for_interval	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "rate", "type": "float"}], "aggregation": "None"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_start_date", "type": "timestamp", "order": 4, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 5, "source": "interval_end"}], "needs_subsys": false}	Non-TOU rates over an interval, one row per run of equal rates	2020-01-01	\N
506	tariff_dev_v2.get_excess_network_capacity_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "max_demand", "type": "float"}, {"name": "excess_kva", "type": "float"}, {"name": "event_number", "type": "int"}, {"name": "deadband_exempt", "type": "boolean"}, {"name": "rate", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_notified_demand", "type": "integer", "order": 4, "source": "context", "context": "notified_demand"}, {"name": "p_subsystem_cuid", "type": "text", "order": 5, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}], "needs_subsys": true}	Excess network capacity charge: MD above NMD x rate x event number (rolling 12 months, 5% deadband)	2020-01-01	\N
507	tariff_dev_v2.get_network_charge_topup_dx_generators	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "generator_charge", "type": "float"}, {"name": "losses_rebate", "type": "float"}, {"name": "generator_side", "type": "float"}, {"name": "load_side", "type": "float"}, {"name": "transmission_network", "type": "float"}, {"name": "distribution_capacity", "type": "float"}, {"name": "distribution_demand", "type": "float"}, {"name": "mec", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_subsystem_cuid", "type": "text", "order": 2, "source": "context", "context": "subsystem_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 3, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 4, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 5, "source": "attribute_value_ids"}, {"name": "p_mec", "type": "numeric", "order": 6, "source": "context", "context": "maximum_export_capacity"}, {"name": "p_notified_demand", "type": "integer", "order": 7, "source": "context", "context": "notified_demand"}, {"name": "p_std_val_column", "type": "text", "order": 8, "source": "context", "context": "std_val_column"}, {"name": "p_start_date", "type": "timestamp", "order": 9, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 10, "source": "interval_end"}], "needs_subsys": true}	Megaflex Gen (Distribution connected): max(0, MEC x Dx gen rate less losses rebate - Tx + Dx capacity + Dx demand load charges)	2020-01-01	\N
508	tariff_dev_v2.get_network_charge_topup_tx_generators	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "generator_side", "type": "float"}, {"name": "load_side", "type": "float"}, {"name": "mec", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_subsystem_cuid", "type": "text", "order": 1, "source": "context", "context": "subsystem_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 4, "source": "attribute_value_ids"}, {"name": "p_mec", "type": "numeric", "order": 5, "source": "context", "context": "maximum_export_capacity"}, {"name": "p_notified_demand", "type": "integer", "order": 6, "source": "context", "context": "notified_demand"}, {"name": "p_start_date", "type": "timestamp", "order": 7, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 8, "source": "interval_end"}], "needs_subsys": true}	Megaflex Gen (Transmission connected): max(0, MEC x Tx gen rate - Tx network load charge)	2020-01-01	\N
509	tariff_dev_v2.get_excess_mec_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "max_export", "type": "float"}, {"name": "excess_kw", "type": "float"}, {"name": "event_number", "type": "int"}, {"name": "deadband_exempt", "type": "boolean"}, {"name": "mec", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 4, "source": "attribute_value_ids"}, {"name": "p_mec", "type": "numeric", "order": 5, "source": "context", "context": "maximum_export_capacity"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}], "needs_subsys": false}	Excess MEC charge: max hourly export above MEC x rate x event number (NMD-rule deadband)	2020-01-01	\N
510	tariff_dev_v2.get_monthly_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "rate", "type": "float"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_start_date", "type": "timestamp", "order": 4, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 5, "source": "interval_end"}], "needs_subsys": false}	Fixed R/month charge for a billing month, prorated by days across a rate change	2020-01-01	\N
511	tariff_dev_v2.get_nmd_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "nmd", "type": "float"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_notified_demand", "type": "integer", "order": 4, "source": "context", "context": "notified_demand"}, {"name": "p_start_date", "type": "timestamp", "order": 5, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 6, "source": "interval_end"}], "needs_subsys": false}	Municipal NMD charge: NMD x R/kVA/month, prorated by days across a rate change	2020-01-01	\N
512	tariff_dev_v2.get_nmd_exceedance_surcharge_municipal	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "max_demand", "type": "float"}, {"name": "occasion", "type": "int"}, {"name": "surcharge_pct", "type": "int"}, {"name": "nmd_charge", "type": "float"}, {"name": "disconnection_risk", "type": "boolean"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_notified_demand", "type": "integer", "order": 4, "source": "context", "context": "notified_demand"}, {"name": "p_subsystem_cuid", "type": "text", "order": 5, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}], "needs_subsys": true}	Municipal NMD exceedance surcharge: 10/20/30% of the NMD charge on the 2nd/3rd/4th+ exceedance in the financial year	2020-01-01	\N
513	tariff_dev_v2.get_utilised_capacity_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "utilised_capacity", "type": "float"}, {"name": "max_demand", "type": "float"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_notified_demand", "type": "integer", "order": 4, "source": "context", "context": "notified_demand"}, {"name": "p_subsystem_cuid", "type": "text", "order": 5, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}], "needs_subsys": true}	Utilised capacity charge: greatest(NMD, month peak 30-minute kVA) x R/kVA/month	2020-01-01	\N
514	tariff_dev_v2.get_nmd_exceedance_charge_overstrand	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "max_demand", "type": "float"}, {"name": "excess_kva", "type": "float"}, {"name": "warning", "type": "boolean"}, {"name": "subsys", "type": "text"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_notified_demand", "type": "integer", "order": 4, "source": "context", "context": "notified_demand"}, {"name": "p_subsystem_cuid", "type": "text", "order": 5, "source": "context", "context": "subsystem_cuid"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}], "needs_subsys": true}	Overstrand NMD exceedance: warning after 12 clear months, else excess kVA x R/kVA	2020-01-01	\N
515	tariff_dev_v2.get_rate_at_interval_end	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "rate", "type": "float"}], "aggregation": "None"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_start_date", "type": "timestamp", "order": 4, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 5, "source": "interval_end"}], "needs_subsys": false}	Non-TOU rate in force on the last day of the interval	2020-01-01	\N
516	tariff_dev_v2.get_reactive_energy_charge_cost	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "kvarh", "type": "float"}, {"name": "kwh", "type": "float"}, {"name": "excess_kvarh", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "season_id", "type": "int"}], "aggregation": "none"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_entity_cuid", "type": "text", "order": 4, "source": "context", "context": "pod_entity_cuid"}, {"name": "p_kwh_parameter_id", "type": "text", "order": 5, "source": "context", "context": "pod_kwh_parameter_id"}, {"name": "p_kvarh_parameter_id", "type": "text", "order": 6, "source": "context", "context": "pod_kvarh_parameter_id"}, {"name": "p_start_date", "type": "timestamp", "order": 7, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 8, "source": "interval_end"}], "needs_subsys": false}	Reactive energy charge on kvarh above 30% of kWh, billing-period totals	2020-01-01	\N
523	tariff_dev_v2.get_block_energy_cost_from_std_val_hourly	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "cost", "type": "float"}, {"name": "energy", "type": "float"}, {"name": "rate", "type": "float"}, {"name": "block_from", "type": "float"}], "aggregation": "sum"}, "parameters": [{"name": "p_system_cuid", "type": "text", "order": 1, "source": "context", "context": "system_cuid"}, {"name": "p_tariff_id", "type": "integer", "order": 2, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 3, "source": "context", "context": "rate_class_id"}, {"name": "p_std_val_column", "type": "text", "order": 4, "source": "context", "context": "std_val_column"}, {"name": "p_dwelling_units", "type": "integer", "order": 5, "source": "context", "context": "dwelling_units"}, {"name": "p_start_date", "type": "timestamp", "order": 6, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 7, "source": "interval_end"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 8, "source": "attribute_value_ids"}], "needs_subsys": false}	Inclining-block c/kWh charge on the system's hourly energy, block limits per dwelling unit x units x days / 30.4375	2020-01-01	\N
524	tariff_dev_v2.get_block_rates_for_interval	{"returns": {"type": "table", "columns": [{"name": "timestamp", "type": "int"}, {"name": "rate", "type": "float"}, {"name": "block_from", "type": "float"}, {"name": "season", "type": "text"}], "aggregation": "None"}, "parameters": [{"name": "p_tariff_id", "type": "integer", "order": 1, "source": "context", "context": "tariff_id"}, {"name": "p_rate_class_id", "type": "integer", "order": 2, "source": "context", "context": "rate_class_id"}, {"name": "p_attribute_value_ids", "type": "integer[]", "order": 3, "source": "attribute_value_ids"}, {"name": "p_start_date", "type": "timestamp", "order": 4, "source": "interval_start"}, {"name": "p_end_date", "type": "timestamp", "order": 5, "source": "interval_end"}], "needs_subsys": false}	Block rates over an interval, one row per rate era (rate period x season) and block	2020-01-01	\N
\.

COPY tariff_dev_v2.public_holidays (holiday_date, holiday_name, source) FROM stdin;
2024-04-01	Family Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-04-27	Freedom Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-05-01	Workers Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-06-16	Youth Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-06-17	Public Holiday	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-08-09	National Women's Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-09-24	Heritage Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-12-16	Day of Reconciliation	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-12-25	Christmas Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2024-12-26	Day of Goodwill	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2025-01-01	New Year's Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2025-03-21	Human Rights Day	Eskom schedule Schedule-of-standard-prices-2024_25-V1.pdf
2025-04-18	Good Friday	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-04-21	Family Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-04-27	Freedom Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-04-28	Public Holiday	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-05-01	Workers Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-06-16	Youth Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-08-09	National Women's Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-09-24	Heritage Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-12-16	Day of Reconciliation	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-12-25	Christmas Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2025-12-26	Day of Goodwill	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2026-01-01	New Year's Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2026-03-21	Human Rights Day	Eskom schedule 20250401-Schedule-of-standard-prices-2025_26.pdf
2026-04-03	Good Friday	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-04-06	Family Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-04-27	Freedom Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-05-01	Workers Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-06-16	Youth Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-08-09	National Women's Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-08-10	Public Holiday	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-09-24	Heritage Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-12-16	Day of Reconciliation	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-12-25	Christmas Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2026-12-26	Day of Goodwill	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-01-01	New Year's Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-03-21	Human Rights Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-03-22	Public Holiday	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-03-26	Good Friday	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-03-29	Family Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-04-27	Freedom Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-05-01	Worker's Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
2027-06-16	Youth Day	Eskom schedule 20260226-Schedule-of-standard-prices-for-01-April-2026-Public-1.pdf
\.

COPY tariff_dev_v2.rate_class_attributes (rate_class_id, attribute_id) FROM stdin;
1	1
1	2
2	3
3	1
3	2
8	2
7	1
7	2
9	1
9	2
16	2
12	4
13	4
11	2
10	2
18	3
19	3
20	3
21	3
24	1
24	2
25	2
26	2
27	2
36	5
37	2
39	1
40	2
41	5
42	5
43	2
\.

COPY tariff_dev_v2.rate_class_operation_implementation (rate_class_id, operation_id, signature_id, description, valid_from, valid_to) FROM stdin;
6	1	500	TOU tou_cost_total	\N	\N
6	2	500	TOU tou_cost_off_peak	\N	\N
6	3	500	TOU tou_cost_standard	\N	\N
6	4	500	TOU tou_cost_peak	\N	\N
6	7	500	TOU tou_energy_total	\N	\N
6	8	500	TOU tou_energy_off_peak	\N	\N
6	9	500	TOU tou_energy_standard	\N	\N
6	10	500	TOU tou_energy_peak	\N	\N
15	1	500	TOU tou_cost_total	\N	\N
15	2	500	TOU tou_cost_off_peak	\N	\N
15	3	500	TOU tou_cost_standard	\N	\N
15	4	500	TOU tou_cost_peak	\N	\N
15	7	500	TOU tou_energy_total	\N	\N
15	8	500	TOU tou_energy_off_peak	\N	\N
15	9	500	TOU tou_energy_standard	\N	\N
15	10	500	TOU tou_energy_peak	\N	\N
17	1	500	TOU tou_cost_total	\N	\N
17	2	500	TOU tou_cost_off_peak	\N	\N
17	3	500	TOU tou_cost_standard	\N	\N
17	4	500	TOU tou_cost_peak	\N	\N
17	7	500	TOU tou_energy_total	\N	\N
17	8	500	TOU tou_energy_off_peak	\N	\N
17	9	500	TOU tou_energy_standard	\N	\N
17	10	500	TOU tou_energy_peak	\N	\N
22	1	500	TOU tou_cost_total	\N	\N
22	2	500	TOU tou_cost_off_peak	\N	\N
22	3	500	TOU tou_cost_standard	\N	\N
22	4	500	TOU tou_cost_peak	\N	\N
22	7	500	TOU tou_energy_total	\N	\N
22	8	500	TOU tou_energy_off_peak	\N	\N
22	9	500	TOU tou_energy_standard	\N	\N
22	10	500	TOU tou_energy_peak	\N	\N
23	1	500	TOU tou_cost_total	\N	\N
23	2	500	TOU tou_cost_off_peak	\N	\N
23	3	500	TOU tou_cost_standard	\N	\N
23	4	500	TOU tou_cost_peak	\N	\N
23	7	500	TOU tou_energy_total	\N	\N
23	8	500	TOU tou_energy_off_peak	\N	\N
23	9	500	TOU tou_energy_standard	\N	\N
23	10	500	TOU tou_energy_peak	\N	\N
1	1	500	TOU tou_cost_total	\N	\N
1	2	500	TOU tou_cost_off_peak	\N	\N
1	3	500	TOU tou_cost_standard	\N	\N
1	4	500	TOU tou_cost_peak	\N	\N
1	7	500	TOU tou_energy_total	\N	\N
1	8	500	TOU tou_energy_off_peak	\N	\N
1	9	500	TOU tou_energy_standard	\N	\N
1	10	500	TOU tou_energy_peak	\N	\N
47	1	500	TOU tou_cost_total	\N	\N
47	2	500	TOU tou_cost_off_peak	\N	\N
47	3	500	TOU tou_cost_standard	\N	\N
47	4	500	TOU tou_cost_peak	\N	\N
47	7	500	TOU tou_energy_total	\N	\N
47	8	500	TOU tou_energy_off_peak	\N	\N
47	9	500	TOU tou_energy_standard	\N	\N
47	10	500	TOU tou_energy_peak	\N	\N
51	1	500	TOU tou_cost_total	\N	\N
51	2	500	TOU tou_cost_off_peak	\N	\N
51	3	500	TOU tou_cost_standard	\N	\N
51	4	500	TOU tou_cost_peak	\N	\N
51	7	500	TOU tou_energy_total	\N	\N
51	8	500	TOU tou_energy_off_peak	\N	\N
51	9	500	TOU tou_energy_standard	\N	\N
51	10	500	TOU tou_energy_peak	\N	\N
52	1	500	TOU tou_cost_total	\N	\N
52	2	500	TOU tou_cost_off_peak	\N	\N
52	3	500	TOU tou_cost_standard	\N	\N
52	4	500	TOU tou_cost_peak	\N	\N
52	7	500	TOU tou_energy_total	\N	\N
52	8	500	TOU tou_energy_off_peak	\N	\N
52	9	500	TOU tou_energy_standard	\N	\N
52	10	500	TOU tou_energy_peak	\N	\N
35	1	500	TOU tou_cost_total	\N	\N
35	2	500	TOU tou_cost_off_peak	\N	\N
35	3	500	TOU tou_cost_standard	\N	\N
35	4	500	TOU tou_cost_peak	\N	\N
35	7	500	TOU tou_energy_total	\N	\N
35	8	500	TOU tou_energy_off_peak	\N	\N
35	9	500	TOU tou_energy_standard	\N	\N
35	10	500	TOU tou_energy_peak	\N	\N
59	1	500	TOU tou_cost_total	\N	\N
59	2	500	TOU tou_cost_off_peak	\N	\N
59	3	500	TOU tou_cost_standard	\N	\N
59	4	500	TOU tou_cost_peak	\N	\N
59	7	500	TOU tou_energy_total	\N	\N
59	8	500	TOU tou_energy_off_peak	\N	\N
59	9	500	TOU tou_energy_standard	\N	\N
59	10	500	TOU tou_energy_peak	\N	\N
6	19	501	TOU rate_info	\N	\N
15	19	501	TOU rate_info	\N	\N
17	19	501	TOU rate_info	\N	\N
22	19	501	TOU rate_info	\N	\N
23	19	501	TOU rate_info	\N	\N
1	19	501	TOU rate_info	\N	\N
26	19	501	TOU rate_info	\N	\N
30	19	501	TOU rate_info	\N	\N
47	19	501	TOU rate_info	\N	\N
51	19	501	TOU rate_info	\N	\N
52	19	501	TOU rate_info	\N	\N
49	19	501	TOU rate_info	\N	\N
35	19	501	TOU rate_info	\N	\N
59	19	501	TOU rate_info	\N	\N
10	14	502	distribution_network_demand_charge	\N	\N
8	16	502	legacy_charge	\N	\N
11	15	502	ancillary_service_charge	\N	\N
28	24	502	electrification_rural_subsidy_charge	\N	\N
29	25	502	affordability_subsidy_charge	\N	\N
33	30	502	energy_charge	\N	\N
2	30	502	energy_charge	\N	\N
55	37	502	network_surcharge	\N	\N
56	38	502	export_credit	\N	\N
12	13	503	service_charge	\N	\N
13	12	503	admin_charge	\N	\N
7	17	504	generation_capacity_charge	\N	\N
9	18	504	network_capacity_charge_charge	\N	\N
24	18	504	network_capacity_charge_charge	\N	\N
25	18	504	network_capacity_charge_charge	\N	\N
27	18	504	network_capacity_charge_charge	\N	\N
2	19	505	rate_info	\N	\N
8	19	505	rate_info	\N	\N
11	19	505	rate_info	\N	\N
12	19	505	rate_info	\N	\N
13	19	505	rate_info	\N	\N
10	19	505	rate_info	\N	\N
28	19	505	rate_info	\N	\N
29	19	505	rate_info	\N	\N
33	19	505	rate_info	\N	\N
55	19	505	rate_info	\N	\N
56	19	505	rate_info	\N	\N
3	21	506	excess_network_capacity_charge	\N	\N
37	26	507	network_charge_generators_topup	\N	\N
36	26	508	network_charge_generators_topup	\N	\N
42	27	509	excess_mec_charge	\N	\N
43	27	509	excess_mec_charge	\N	\N
31	28	510	fixed_monthly_charge	\N	\N
32	29	510	meter_reading_charge	\N	\N
54	36	510	monthly_capacity_charge	\N	\N
34	31	511	nmd_charge	\N	\N
44	32	512	nmd_exceedance_surcharge	\N	\N
45	34	513	utilised_capacity_charge	\N	\N
46	35	514	nmd_exceedance_charge	\N	\N
3	19	515	rate_info	\N	\N
5	19	515	rate_info	\N	\N
7	19	515	rate_info	\N	\N
9	19	515	rate_info	\N	\N
24	19	515	rate_info	\N	\N
25	19	515	rate_info	\N	\N
27	19	515	rate_info	\N	\N
31	19	515	rate_info	\N	\N
32	19	515	rate_info	\N	\N
34	19	515	rate_info	\N	\N
36	19	515	rate_info	\N	\N
37	19	515	rate_info	\N	\N
42	19	515	rate_info	\N	\N
43	19	515	rate_info	\N	\N
44	19	515	rate_info	\N	\N
45	19	515	rate_info	\N	\N
46	19	515	rate_info	\N	\N
48	19	515	rate_info	\N	\N
53	19	515	rate_info	\N	\N
54	19	515	rate_info	\N	\N
14	20	516	reactive_energy_charge	\N	\N
38	23	518	losses_charge_tx_generators	\N	\N
26	14	519	distribution_network_demand_charge	\N	\N
5	33	519	maximum_demand_charge	\N	\N
48	33	520	maximum_demand_charge	\N	\N
49	33	520	maximum_demand_charge	\N	\N
53	33	521	maximum_demand_charge	\N	\N
30	20	522	reactive_energy_charge	\N	\N
57	30	523	energy_charge	\N	\N
58	37	523	network_surcharge	\N	\N
57	19	524	rate_info	\N	\N
58	19	524	rate_info	\N	\N
\.

COPY tariff_dev_v2.rate_class_tou_periods (rate_class_id, period_id, period_label, sort_order) FROM stdin;
1	1	\N	1
6	2	\N	2
4	2	\N	2
4	3	\N	3
23	1	\N	1
4	1	\N	1
6	3	\N	3
22	2	\N	2
23	2	\N	2
15	3	\N	3
1	2	\N	2
6	1	\N	1
23	3	\N	3
22	1	\N	1
22	3	\N	3
15	1	\N	1
1	3	\N	3
15	2	\N	2
5	4	\N	4
17	4	\N	4
9	4	\N	4
7	4	\N	4
14	4	\N	4
3	4	\N	4
10	4	\N	4
13	4	\N	4
2	4	\N	4
8	4	\N	4
11	4	\N	4
12	4	\N	4
35	1	\N	1
35	2	\N	2
35	3	\N	3
38	1	\N	1
38	2	\N	2
38	3	\N	3
26	1	\N	1
26	2	\N	2
30	1	\N	1
30	2	\N	2
47	1	\N	1
47	2	\N	2
47	3	\N	3
49	1	\N	1
49	2	\N	2
51	1	\N	1
51	2	\N	2
51	3	\N	3
52	4	\N	1
59	1	\N	1
59	2	\N	2
59	3	\N	3
\.

COPY tariff_dev_v2.rate_class_tou_seasons (rate_class_id, season_id, season_label, sort_order) FROM stdin;
1	1	\N	1
6	2	\N	2
17	1	\N	1
4	2	\N	2
22	1	\N	1
15	1	\N	1
23	1	\N	1
4	1	\N	1
22	2	\N	2
15	2	\N	2
23	2	\N	2
1	2	\N	2
17	2	\N	2
6	1	\N	1
14	2	\N	2
2	3	\N	3
3	3	\N	3
9	3	\N	3
12	3	\N	3
8	3	\N	3
7	3	\N	3
10	3	\N	3
11	3	\N	3
5	3	\N	3
14	1	\N	1
13	3	\N	3
30	1	\N	1
30	2	\N	2
35	1	\N	1
35	2	\N	2
38	1	\N	1
38	2	\N	2
26	1	\N	1
26	2	\N	2
47	1	\N	1
47	2	\N	2
49	1	\N	1
49	2	\N	2
51	1	Winter	1
51	2	Summer	2
52	1	Winter	1
52	2	Summer	2
57	1	Winter	1
57	2	Summer	2
57	3	\N	3
59	1	\N	1
59	2	\N	2
\.

COPY tariff_dev_v2.rate_classes (rate_class_id, rate_key, class_code, description, cost_unit, rate_type, created_at, updated_at) FROM stdin;
18	drakenstein_fixed	Drakenstein Bulk Fixed Monthly	The monthly fixed charge for bulk and large bulk users.	month	fixed	2026-09-10 21:36:13.335352	2026-09-14 13:24:59.813849
19	drakenstein_demand	Drakenstein Bulk Demand	The demand charge per kVA for bulk and large bulk users.	kVA	demand	2026-09-10 21:36:13.335352	2026-09-14 13:24:59.813849
20	drakenstein_energy	Drakenstein Bulk Energy	The energy charge per kWh for bulk and large bulk users.	kWh	energy	2026-09-10 21:36:13.335352	2026-09-14 13:24:59.813849
21	drakenstein_co_generation	Drakenstein Bulk Co-generation	The co-generation charge per kWh for bulk and large bulk users.	kWh	energy	2026-09-10 21:36:13.335352	2026-09-14 13:24:59.813849
2	generic_flat	Generic Flat Rate	Generic flat rate energy charges	kWh	energy	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
3	excess_net_capacity_charge	Excess Network Capacity Charge [ENCC]	Payable in the event of an NMD exceedance as specified in paragraph 6 in accordance with the NMD rules and as set out in Table 36 and Table 37 for the relevant tariff. Based on the maximum demand exceeding the NMD multiplied by the event number (recorded every time the NMD is exceeded) multiplied by the applicable network capacity charges for the tariff (refer further to paragraph 6)	kVA	demand	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
4	coct_tou	City of Cape Town TOU	Seasonally and time-of-use differentiated c/kWh active energy charges per kWh.	kWh	tou	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
5	demand_charge	Demand Charge	A monthly demand charge based on the peak 30min demand.	kVA	demand	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
6	overstrand_tou	Overstrand TOU	Overstrand Municipality seasonally and time-of-use differentiated c/kWh active energy charges per kWh.	kWh	tou	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
7	generation_capacity_charge	Generation Capacity Charge [GCC]	A R/kVA/month generation capacity charge based on the voltage of the supply and the annual utilised capacity measured at the POD applicable during all time periods.	kVA/month	demand	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
8	legacy_charge	Legacy Charge [LGCY]	A c/kWh legacy charge based on the voltage of supply applicable during all time periods.	kWh	energy	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
9	net_capacity_charge	Network Capacity Charge [NCC]	A R/kVA/month network capacity charge combining the Transmission and Distribution network capacity charges based on the voltage of the supply, the Transmission zone and the annual utilised capacity measured at the POD applicable during all time periods. Annual utilised capacity means the higher of the notified maximum demand (NMD) or the maximum demand, per POD/point of supply measured in kVA, and registered during a rolling 12-month period	kVA/month	demand	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
11	ancillary_service_charge	Ancillary Service Charge [ASC]	A c/kWh ancillary service charge based on the voltage of the supply applicable during all time periods.	kWh	energy	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
12	service_charge	Service Charge [SVC]	A R/POD/day service charge based on the monthly utilised capacity of each POD linked to an account.	day	fixed	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
14	reactive_energy_charge	Reactive Energy Charge [REAC]	A c/kVArh reactive energy charge supplied in excess of 30% (0,96 power factor or less) of the kWh recorded during the entire billing period. The excess reactive energy is determined using the billing period totals and will only be applicable during the high-demand season.	kVArh	energy	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
15	bergriver_tou	Bergriver TOU	Seasonally and time-of-use differentiated c/kWh active energy charges per kWh.	kWh	tou	2026-07-31 18:48:42.645544	2026-09-14 13:24:59.813849
16	net_demand_charge	Network Demand Charge [NDC]	R/kVA or c/kWh variable network charge raised to recover network costs and depending on the tariff may be charged on the chargeable demand or the active energy.	kWh/kVA	demand	2026-08-02 13:19:54.480721	2026-09-14 13:24:59.813849
17	mining_seasonal	mining Seasonal	Mining customer seasonal tariff with a flat rate per season.	kWh	tou	2026-08-11 15:43:43.409163	2026-09-14 13:24:59.813849
22	kouga_tou	Kouga TOU	Seasonally and time-of-use differentiated c/kWh active energy charges per kWh.	kWh	tou	2026-09-14 18:02:50.697299	2026-09-14 18:02:50.697299
23	tzaneen_tou	Tzaneen TOU	Tzaneen Municipality seasonally and time-of-use differentiated c/kWh active energy charges per kWh.	kWh	tou	2026-10-15 19:20:43.764981	2026-10-15 19:20:43.764981
1	eskom_tou	Eskom TOU	Seasonally and time-of-use differentiated c/kWh active energy charges including losses, based on the voltage of supply and the Transmission zone.	kWh	tou	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
13	admin_charge	Admin Charge [ADM]	A R/POD/day administration charge based on the monthly utilised capacity of each POD linked to an account.	day	fixed	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
10	distribution_net_demand_charge	Distribution Network Demand Charge [DNDC]	A c/kWh Distribution network demand charge based on the voltage of the supply and the energy measured at the POD during all TOU periods	kWh	energy	2026-07-19 18:22:26.631087	2026-09-14 13:24:59.813849
24	transmission_network_charge	Transmission Network Charge [TNC]	A R/kVA/month Transmission network charge based on the voltage of the supply, the Transmission zone and the annual utilised capacity measured at the POD applicable during all time periods.	kVA/month	demand	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
25	distribution_net_capacity_charge	Distribution Network Capacity Charge [DNCC]	A R/kVA/month Distribution network capacity charge based on the voltage of the supply and the annual utilised capacity measured at the POD applicable during all time periods.	kVA/month	demand	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
26	distribution_net_demand_charge_kva	Distribution Network Demand Charge, kVA [DNDC-kVA]	A R/kVA/month Distribution network demand charge based on the voltage of the supply and the chargeable demand measured at the POD applicable during peak and standard periods.	kVA/month	demand	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
27	urban_lv_subsidy_charge	Urban Low Voltage Subsidy Charge [ULVSC]	A R/kVA/month urban low voltage subsidy charge based on the voltage of the supply and charged on the annual utilised capacity measured at the POD applicable during all time periods.	kVA/month	demand	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
28	electrification_rural_subsidy_charge	Electrification and Rural Network Subsidy Charge [ERNSC]	A c/kWh electrification and rural network subsidy charge, applied to the total active energy measured at the POD in the month.	kWh	energy	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
29	affordability_subsidy_charge	Affordability Subsidy Charge [AFSC]	A c/kWh affordability subsidy charge applied to the total active energy measured at the POD in the month, applicable to non-local authority tariffs only.	kWh	energy	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
30	reactive_energy_charge_pk_std	Reactive Energy Charge, peak and standard [REAC-PS]	A c/kVArh reactive energy charge supplied in excess of 30% (0,96 power factor or less) of the kWh recorded during the peak and standard periods. The excess reactive energy is determined per 30-minute integrating period and accumulated for the month and will only be applicable during the high-demand season.	kVArh	energy	2026-11-17 06:41:18.627393	2026-11-17 06:41:18.627393
31	fixed_monthly_charge	Fixed Monthly Charge [FMC]	A R/month fixed charge per point of supply.	month	fixed	2026-11-17 11:43:10.228207	2026-11-17 11:43:10.228207
32	meter_reading_charge	Meter Reading Charge [MRC]	A R/month meter reading charge per point of supply.	month	fixed	2026-11-17 11:43:10.228207	2026-11-17 11:43:10.228207
33	energy_charge	Energy Charge [EC]	A c/kWh active energy charge, the same in all seasons and periods.	kWh	energy	2026-11-17 11:43:10.228207	2026-11-17 11:43:10.228207
34	nmd_charge	Notified Maximum Demand Charge [NMDC]	A R/kVA/month charge on the notified maximum demand (NMD).	kVA/month	demand	2026-11-17 11:43:10.228207	2026-11-17 11:43:10.228207
36	tx_network_charge_generators	Transmission Network Charge, generators [TNC-G]	A R/kW/month Transmission network charge (TUoS) for Transmission connected generators, based on the Transmission zone for generators and the maximum export capacity, applicable during all time periods.	kW/month	demand	2026-11-17 12:35:22.797799	2026-11-17 12:35:22.797799
37	dx_network_capacity_charge_generators	Distribution Network Capacity Charge, generators [DNCC-G]	A R/kW/month Distribution network capacity charge for generators, based on the voltage of the supply and the maximum export capacity measured at the POD, applicable during all time periods; rebated by the losses charge, but not beyond extinction.	kW/month	demand	2026-11-17 12:35:22.797799	2026-11-17 12:35:22.797799
38	weps_energy_rate_excl_losses	WEPS Energy Rate excluding losses [WEPS-XL]	The WEPS c/kWh energy rate excluding losses (and the portion of the generation capacity charge), per season and TOU period. A reference rate for the generator losses charge, not billed by itself.	kWh	tou	2026-11-17 12:35:22.797799	2026-11-17 12:35:22.797799
39	transmission_loss_factor	Transmission Loss Factor [TLF]	The Transmission loss factor for loads and Distribution connected generators, by Transmission zone. A plain factor, not cents.	factor	factor	2026-11-17 12:35:22.797799	2026-11-17 12:35:22.797799
40	distribution_loss_factor	Distribution Loss Factor [DLF]	The Distribution loss factor by voltage of supply (urban or rural, as the tariff applies). A plain factor, not cents.	factor	factor	2026-11-17 12:35:22.797799	2026-11-17 12:35:22.797799
41	generator_loss_factor	Generator Loss Factor [GLF]	The loss factor for Transmission connected generators, by Transmission zone for generators. A plain factor, not cents.	factor	factor	2026-11-17 12:35:22.797799	2026-11-17 12:35:22.797799
42	excess_mec_charge_tx_generators	Excess MEC Charge, Transmission connected generators [EMEC-T]	A R/kW/month excess network capacity charge payable in the event of an exceedance of the maximum export capacity (MEC) by a Transmission connected generator, by Transmission zone for generators, in accordance with the NMD and MEC rules.	kW/month	demand	2026-11-17 13:31:46.200105	2026-11-17 13:31:46.200105
43	excess_mec_charge_dx_generators	Excess MEC Charge, Distribution connected generators [EMEC-D]	A R/kW/month excess network capacity charge payable in the event of an exceedance of the maximum export capacity (MEC) by a Distribution connected generator, by voltage of supply, in accordance with the NMD and MEC rules.	kW/month	demand	2026-11-17 13:31:46.200105	2026-11-17 13:31:46.200105
44	nmd_exceedance_surcharge_stellenbosch	NMD Exceedance Surcharge, Stellenbosch [NMDES]	Stellenbosch: a surcharge of the rate (%) of the month's NMD charge per occasion after the first that the NMD is exceeded in a municipal financial year (10% on the 2nd, 20% on the 3rd, 30% on the 4th and later occasions).	percent	demand	2026-11-19 06:58:08.290956	2026-11-19 06:58:08.290956
45	utilised_capacity_charge	Utilised Capacity Charge [UCC]	A R/kVA/month network demand charge on the utilised capacity: the higher of the notified maximum demand (NMD) and the peak 30-minute kVA registered in the billing month.	kVA/month	demand	2026-11-19 06:58:08.290956	2026-11-19 06:58:08.290956
46	nmd_exceedance_charge_overstrand	NMD Exceedance Charge, Overstrand [NMDEC]	Overstrand: a R/kVA charge on the kVA by which the NMD is exceeded in a billing month, from the second exceedance within 12 consecutive months (the first is a warning).	kVA/month	demand	2026-11-19 06:58:08.290956	2026-11-19 06:58:08.290956
47	tshwane_tou	Tshwane TOU	City of Tshwane seasonally and time-of-use differentiated c/kWh active energy charges.	kWh	tou	2026-11-19 09:00:57.142549	2026-11-19 09:00:57.142549
48	tshwane_demand_charge	Tshwane Demand Charge [TDC]	City of Tshwane: a R/kVA charge on the half-hourly maximum demand of the month, all periods, at least the tariff's minimum demand.	kVA	demand	2026-11-19 09:00:57.142549	2026-11-19 09:00:57.142549
50	minimum_demand_kva	Minimum Demand [MIN-kVA]	The minimum demand (kVA) charged by a tariff's demand charge. A quantity, not a price.	kVA (quantity)	demand	2026-11-19 09:00:57.142549	2026-11-19 09:00:57.142549
51	city_power_tou	City Power TOU	City Power seasonally and time-of-use differentiated c/kWh active energy charges, on City Power's TOU hours.	kWh	tou	2026-11-19 11:21:55.059079	2026-11-19 11:21:55.059079
52	city_power_seasonal	City Power Seasonal Energy	City Power seasonally differentiated c/kWh active energy charges (one rate every hour of a season).	kWh	tou	2026-11-19 11:21:55.059079	2026-11-19 11:21:55.059079
53	city_power_demand_charge	City Power Demand Charge [CPDC]	City Power: a R/kVA charge on the month's highest 30-minute demand, all periods, at least the greater of the minimum demand and 80% of the average of the three highest demands of the preceding 12 months.	kVA	demand	2026-11-19 11:21:55.059079	2026-11-19 11:21:55.059079
54	monthly_capacity_charge	Capacity Charge [CAP]	A fixed R/month capacity (network) charge.	month	fixed	2026-11-19 11:21:55.059079	2026-11-19 11:21:55.059079
55	network_surcharge	Network Surcharge [NS]	A c/kWh surcharge on all active energy consumed.	kWh	energy	2026-11-19 11:21:55.059079	2026-11-19 11:21:55.059079
56	export_credit	Export Credit [EXP]	A c/kWh credit on active energy exported to the grid.	kWh	energy	2026-11-19 11:21:55.059079	2026-11-19 11:21:55.059079
49	tshwane_tou_demand_charge	Tshwane TOU Demand Charge [TTDC]	City of Tshwane 2023/24 time-of-use scales: a R/kVA charge on the half-hourly maximum demand in the peak and standard periods. Unused since the 2025/26 schedule charges every period (tshwane_demand_charge).	kVA	demand	2026-11-19 09:00:57.142549	2026-11-19 09:00:57.142549
57	block_energy_charge	Block Energy Charge [BEC]	Inclining-block c/kWh energy charge. block_from is the block's lower limit in kWh per dwelling unit per month; over an interval each limit is scaled by the site's dwelling units x days / 30.4375.	kWh	block	2026-11-20 16:19:41.243286	2026-11-20 16:19:41.243286
58	network_surcharge_residential	Network Surcharge, Residential [NSR]	City Power network surcharge (c/kWh) for residential customers, exempt for the first 500 kWh a month: blocks as block_energy_charge (per dwelling unit, days / 30.4375).	kWh	block	2026-11-20 16:19:41.243286	2026-11-20 16:19:41.243286
35	stellenbosch_tou_export	Stellenbosch TOU Export	Stellenbosch Municipality seasonally and time-of-use differentiated c/kWh export credit rates (the import energy is stellenbosch_tou_import).	kWh	tou	2026-11-17 11:43:10.228207	2026-11-17 11:43:10.228207
59	stellenbosch_tou_import	Stellenbosch TOU Import	Stellenbosch Municipality seasonally and time-of-use differentiated c/kWh import energy rates (TOU tariffs; the export credit is stellenbosch_tou_export).	kWh	tou	2026-11-20 19:08:04.575055	2026-11-20 19:08:04.575055
\.

COPY tariff_dev_v2.rate_operations (operation_id, operation_key, description, parameter_overrides, return_type, created_at) FROM stdin;
1	tou_cost_total	Get the total cost for an interval.	{"override": {"p_period_id": 0}}	cost	2026-07-28 13:49:53.081122
2	tou_cost_off_peak	Get the Off Peak period cost for an interval.	{"override": {"p_period_id": 3}}	cost	2026-07-28 13:49:53.081122
3	tou_cost_standard	Get the Standard period cost for an interval.	{"override": {"p_period_id": 2}}	cost	2026-07-28 13:49:53.081122
4	tou_cost_peak	Get the Peak period cost for an interval.	{"override": {"p_period_id": 1}}	cost	2026-07-28 13:49:53.081122
5	cost_total	Get the total cost for a non TOU tariff.	{}	cost	2026-07-28 13:49:53.081122
6	demand_charge_interval	Get the demand charge for an interval.	{"override": {"p_std_val_column": "extensions"}}	cost	2026-07-28 13:49:53.081122
7	tou_energy_total	Get the total energy for an interval.	{"override": {"p_period_id": 0}}	energy	2026-07-31 17:27:12.969408
8	tou_energy_off_peak	Get the Off Peak period energy for an interval.	{"override": {"p_period_id": 3}}	energy	2026-07-31 17:27:12.969408
9	tou_energy_standard	Get the Standard period energy for an interval.	{"override": {"p_period_id": 2}}	energy	2026-07-31 17:27:12.969408
10	tou_energy_peak	Get the Peak period energy for an interval.	{"override": {"p_period_id": 1}}	energy	2026-07-31 17:27:12.969408
11	energy_total	Get the total energy for a non TOU tariff.	{}	energy	2026-07-31 17:27:12.969408
12	admin_charge	Get the daily admin charges for an interval.	{}	cost	2026-08-09 12:39:55.764632
13	service_charge	Get the daily service charges for an interval.	{}	cost	2026-08-09 12:51:49.255691
14	distribution_network_demand_charge	Get the distribution network demand charges for an interval.	{}	cost	2026-08-09 13:16:44.288248
16	legacy_charge	Get the legacy charges for an interval.	{}	cost	2026-08-09 14:21:03.345294
17	generation_capacity_charge	Get the generation capacity charge.	{}	cost	2026-08-09 15:53:39.784585
18	network_capacity_charge_charge	Get the network capacity charges for an interval.	{}	cost	2026-08-09 15:59:15.812447
19	rate_info	Get the applicable rate(s) for the rate class over an interval.	{}	rate	2026-09-11 17:19:37.573222
15	ancillary_service_charge	Get the ancillary service charges for an interval.	{}	cost	2026-08-09 13:32:18.835362
20	reactive_energy_charge	Get the reactive energy charge (excess kvarh) for a billing period.	{}	cost	2026-11-14 16:16:35.219107
21	excess_network_capacity_charge	Get the excess network capacity charge (NMD exceedance) for a billing period.	{}	cost	2026-11-14 16:16:35.219107
22	losses_charge_dx_generators	Get the distribution losses charge (a rebate, negative) for a Distribution connected generator for an interval.	{}	cost	2026-11-17 19:43:40.341991
23	losses_charge_tx_generators	Get the Transmission losses charge (a rebate, negative) for a Transmission connected generator for an interval.	{}	cost	2026-11-17 19:43:40.341991
24	electrification_rural_subsidy_charge	Get the electrification and rural network subsidy charges for an interval.	{}	cost	2026-11-18 09:47:49.316967
25	affordability_subsidy_charge	Get the affordability subsidy charges for an interval.	{}	cost	2026-11-18 09:47:49.316967
26	network_charge_generators_topup	Get the generator network charge top-up (generator charge on MEC above the load network charges) for an interval.	{}	cost	2026-11-18 11:02:59.402638
27	excess_mec_charge	Get the excess network capacity charge for an MEC exceedance for a billing period.	{}	cost	2026-11-18 11:38:28.594306
28	fixed_monthly_charge	Get the fixed monthly charge for a billing month.	{}	cost	2026-11-18 12:28:17.232219
29	meter_reading_charge	Get the meter reading charge for a billing month.	{}	cost	2026-11-18 12:28:17.232219
30	energy_charge	Get the energy charges (c/kWh) for an interval.	{}	cost	2026-11-18 12:28:17.232219
31	nmd_charge	Get the notified maximum demand charge for a billing month.	{}	cost	2026-11-18 12:28:17.232219
32	nmd_exceedance_surcharge	Get the surcharge for an NMD exceedance under the municipal rule for a billing month.	{}	cost	2026-11-18 12:28:17.232219
33	maximum_demand_charge	Get the maximum demand charge (R/kVA) for a billing month.	{}	cost	2026-11-18 12:28:17.232219
34	utilised_capacity_charge	Get the utilised capacity (network demand) charge for a billing month.	{}	cost	2026-11-19 06:58:08.290956
35	nmd_exceedance_charge	Get the charge for an NMD exceedance (per kVA exceeded) for a billing month.	{}	cost	2026-11-19 06:58:08.290956
36	monthly_capacity_charge	Get the fixed monthly capacity charge for a billing month.	{}	cost	2026-11-19 11:21:55.059079
37	network_surcharge	Get the network surcharge (c/kWh) for an interval.	{}	cost	2026-11-19 11:21:55.059079
38	export_credit	Get the export credit (c/kWh on exported energy) for an interval.	{}	cost	2026-11-19 11:21:55.059079
\.

COPY tariff_dev_v2.rates (rate_id, tariff_id, rate_class_id, pattern_class_id, attribute_collection_id, season_id, period_id, valid_from, valid_to, rate, tax_included, description, block_from) FROM stdin;
275	18	5	3	0	3	4	2026-07-01	2027-06-30	32264.00	f	\N	0
276	19	5	3	0	3	4	2026-07-01	2027-06-30	34476.00	f	\N	0
429	5	15	1	0	1	1	2026-07-01	2027-06-30	774.0000	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026, Nersa - Bergrivier.pdf) p.4 Small Consumer TOU Low Voltage < 50 kVA	0
430	5	15	1	0	1	2	2026-07-01	2027-06-30	267.9400	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026, Nersa - Bergrivier.pdf) p.4 Small Consumer TOU Low Voltage < 50 kVA	0
431	5	15	1	0	1	3	2026-07-01	2027-06-30	207.6300	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026, Nersa - Bergrivier.pdf) p.4 Small Consumer TOU Low Voltage < 50 kVA	0
432	5	15	1	0	2	1	2026-07-01	2027-06-30	379.2800	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026, Nersa - Bergrivier.pdf) p.4 Small Consumer TOU Low Voltage < 50 kVA	0
433	5	15	1	0	2	2	2026-07-01	2027-06-30	256.7000	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026, Nersa - Bergrivier.pdf) p.4 Small Consumer TOU Low Voltage < 50 kVA	0
434	5	15	1	0	2	3	2026-07-01	2027-06-30	207.6300	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026, Nersa - Bergrivier.pdf) p.4 Small Consumer TOU Low Voltage < 50 kVA	0
435	18	15	1	0	1	1	2026-07-01	2027-06-30	255.4200	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Medium Voltage 11kV	0
436	18	15	1	0	1	2	2026-07-01	2027-06-30	239.8400	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Medium Voltage 11kV; DEVIATION kept by decision 2026-11-19: the letter has Standard low season 239.84 / high season 236.09, stored the reverse	0
437	18	15	1	0	1	3	2026-07-01	2027-06-30	221.1000	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Medium Voltage 11kV	0
438	18	15	1	0	2	1	2026-07-01	2027-06-30	255.4200	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Medium Voltage 11kV	0
439	18	15	1	0	2	2	2026-07-01	2027-06-30	236.0900	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Medium Voltage 11kV; DEVIATION kept by decision 2026-11-19: the letter has Standard low season 239.84 / high season 236.09, stored the reverse	0
440	18	15	1	0	2	3	2026-07-01	2027-06-30	221.1000	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Medium Voltage 11kV	0
441	19	15	1	0	1	1	2026-07-01	2027-06-30	255.4200	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Low Voltage > 50 kVA	0
442	19	15	1	0	1	2	2026-07-01	2027-06-30	239.8400	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Low Voltage > 50 kVA; DEVIATION kept by decision 2026-11-19: the letter has Standard low season 239.84 / high season 236.09, stored the reverse	0
443	19	15	1	0	1	3	2026-07-01	2027-06-30	221.1000	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Low Voltage > 50 kVA	0
444	19	15	1	0	2	1	2026-07-01	2027-06-30	255.4200	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Low Voltage > 50 kVA	0
445	19	15	1	0	2	2	2026-07-01	2027-06-30	236.0900	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Low Voltage > 50 kVA; DEVIATION kept by decision 2026-11-19: the letter has Standard low season 239.84 / high season 236.09, stored the reverse	0
446	19	15	1	0	2	3	2026-07-01	2027-06-30	221.1000	f	NERSA approval letter Bergrivier 2026/27 (28 May 2026) p.3 Bulk TOU Low Voltage > 50 kVA	0
\.

COPY tariff_dev_v2.schema_migrations (version) FROM stdin;
20261114163103
20261114164512
20261114171951
20261114172924
20261114173000
20261114180000
20261114181000
20261114190625
20261114190637
20261117080000
20261117090000
20261117091000
20261117100000
20261117110000
20261117120000
20261117121000
20261117130000
20261117140000
20261117141000
20261117141100
20261117141200
20261117142000
20261117150000
20261117151000
20261117160000
20261117170000
20261117180000
20261118080000
20261118100000
20261118120000
20261118140000
20261118160000
20261118180000
20261118200000
20261118220000
20261119080000
20261119081000
20261119100000
20261119120000
20261119121000
20261119140000
20261119141000
20261119160000
20261119161000
20261119180000
20261119181000
20261119200000
20261119220000
20261120100000
20261120101000
20261120120000
20261120121000
20261120122000
20261120130000
20261120131000
20261120140000
20261120141000
20261120150000
20261120151000
20261120160000
20261120161000
20261120170000
20261120180000
20261125122906
\.

COPY tariff_dev_v2.tariff_rate_classes (tariff_id, rate_class_id, valid_from, valid_to) FROM stdin;
18	5	2026-07-01	\N
19	15	2026-07-01	\N
5	15	2026-07-01	\N
19	5	2026-07-01	\N
18	15	2026-07-01	\N
\.

COPY tariff_dev_v2.tariff_tou_pattern_link (link_id, tariff_id, rate_class_id, pattern_class_id, pattern_detail_id, valid_from, valid_to, holiday_scheme_id) FROM stdin;
15	18	15	1	4	2024-04-01	2025-03-31	\N
16	18	15	1	5	2025-04-01	\N	\N
17	19	15	1	4	2024-04-01	2025-03-31	\N
18	19	15	1	5	2025-04-01	\N	\N
30	5	15	1	4	2024-04-01	2025-03-31	\N
31	5	15	1	5	2025-04-01	\N	\N
41	18	5	3	7	2026-07-01	\N	\N
45	19	5	3	7	2026-07-01	\N	\N
\.

COPY tariff_dev_v2.tariffs (tariff_id, tariff_name, country_code, currency, valid_from, valid_to, description) FROM stdin;
5	Bergrivier Municipality	ZA	ZAR	2024-03-01	2029-02-28	Small Consumer Low Voltage TOU
18	Bergrivier Bulk TOU MV	ZA	ZAR	2026-07-01	2029-02-28	Industrial users in the Bergrivier Municipality with a MV [11kV] connection
19	Bergrivier Bulk TOU LV	ZA	ZAR	2026-07-01	2029-02-28	Industrial users in the Bergrivier Municipality with a LV [400V] connection
\.

COPY tariff_dev_v2.tou_pattern_detail (pattern_detail_id, season_id, period_id, month, dow, hour) FROM stdin;
4	2	3	1	0	0
4	2	3	1	0	1
4	2	3	1	0	2
4	2	3	1	0	3
4	2	3	1	0	4
4	2	3	1	0	5
4	2	3	1	0	6
4	2	3	1	0	7
4	2	3	1	0	8
4	2	3	1	0	9
4	2	3	1	0	10
4	2	3	1	0	11
4	2	3	1	0	12
4	2	3	1	0	13
4	2	3	1	0	14
4	2	3	1	0	15
4	2	3	1	0	16
4	2	3	1	0	17
4	2	3	1	0	18
4	2	3	1	0	19
4	2	3	1	0	20
4	2	3	1	0	21
4	2	3	1	0	22
4	2	3	1	0	23
4	2	3	1	1	0
4	2	3	1	1	1
4	2	3	1	1	2
4	2	3	1	1	3
4	2	3	1	1	4
4	2	3	1	1	5
4	2	2	1	1	6
4	2	1	1	1	7
4	2	1	1	1	8
4	2	1	1	1	9
4	2	2	1	1	10
4	2	2	1	1	11
4	2	2	1	1	12
4	2	2	1	1	13
4	2	2	1	1	14
4	2	2	1	1	15
4	2	2	1	1	16
4	2	2	1	1	17
4	2	1	1	1	18
4	2	1	1	1	19
4	2	2	1	1	20
4	2	2	1	1	21
4	2	3	1	1	22
4	2	3	1	1	23
4	2	3	1	2	0
4	2	3	1	2	1
4	2	3	1	2	2
4	2	3	1	2	3
4	2	3	1	2	4
4	2	3	1	2	5
4	2	2	1	2	6
4	2	1	1	2	7
4	2	1	1	2	8
4	2	1	1	2	9
4	2	2	1	2	10
4	2	2	1	2	11
4	2	2	1	2	12
4	2	2	1	2	13
4	2	2	1	2	14
4	2	2	1	2	15
4	2	2	1	2	16
4	2	2	1	2	17
4	2	1	1	2	18
4	2	1	1	2	19
4	2	2	1	2	20
4	2	2	1	2	21
4	2	3	1	2	22
4	2	3	1	2	23
4	2	3	1	3	0
4	2	3	1	3	1
4	2	3	1	3	2
4	2	3	1	3	3
4	2	3	1	3	4
4	2	3	1	3	5
4	2	2	1	3	6
4	2	1	1	3	7
4	2	1	1	3	8
4	2	1	1	3	9
4	2	2	1	3	10
4	2	2	1	3	11
4	2	2	1	3	12
4	2	2	1	3	13
4	2	2	1	3	14
4	2	2	1	3	15
4	2	2	1	3	16
4	2	2	1	3	17
4	2	1	1	3	18
4	2	1	1	3	19
4	2	2	1	3	20
4	2	2	1	3	21
4	2	3	1	3	22
4	2	3	1	3	23
4	2	3	1	4	0
4	2	3	1	4	1
4	2	3	1	4	2
4	2	3	1	4	3
4	2	3	1	4	4
4	2	3	1	4	5
4	2	2	1	4	6
4	2	1	1	4	7
4	2	1	1	4	8
4	2	1	1	4	9
4	2	2	1	4	10
4	2	2	1	4	11
4	2	2	1	4	12
4	2	2	1	4	13
4	2	2	1	4	14
4	2	2	1	4	15
4	2	2	1	4	16
4	2	2	1	4	17
4	2	1	1	4	18
4	2	1	1	4	19
4	2	2	1	4	20
4	2	2	1	4	21
4	2	3	1	4	22
4	2	3	1	4	23
4	2	3	1	5	0
4	2	3	1	5	1
4	2	3	1	5	2
4	2	3	1	5	3
4	2	3	1	5	4
4	2	3	1	5	5
4	2	2	1	5	6
4	2	1	1	5	7
4	2	1	1	5	8
4	2	1	1	5	9
4	2	2	1	5	10
4	2	2	1	5	11
4	2	2	1	5	12
4	2	2	1	5	13
4	2	2	1	5	14
4	2	2	1	5	15
4	2	2	1	5	16
4	2	2	1	5	17
4	2	1	1	5	18
4	2	1	1	5	19
4	2	2	1	5	20
4	2	2	1	5	21
4	2	3	1	5	22
4	2	3	1	5	23
4	2	3	1	6	0
4	2	3	1	6	1
4	2	3	1	6	2
4	2	3	1	6	3
4	2	3	1	6	4
4	2	3	1	6	5
4	2	3	1	6	6
4	2	2	1	6	7
4	2	2	1	6	8
4	2	2	1	6	9
4	2	2	1	6	10
4	2	2	1	6	11
4	2	3	1	6	12
4	2	3	1	6	13
4	2	3	1	6	14
4	2	3	1	6	15
4	2	3	1	6	16
4	2	3	1	6	17
4	2	2	1	6	18
4	2	2	1	6	19
4	2	3	1	6	20
4	2	3	1	6	21
4	2	3	1	6	22
4	2	3	1	6	23
4	2	3	2	0	0
4	2	3	2	0	1
4	2	3	2	0	2
4	2	3	2	0	3
4	2	3	2	0	4
4	2	3	2	0	5
4	2	3	2	0	6
4	2	3	2	0	7
4	2	3	2	0	8
4	2	3	2	0	9
4	2	3	2	0	10
4	2	3	2	0	11
4	2	3	2	0	12
4	2	3	2	0	13
4	2	3	2	0	14
4	2	3	2	0	15
4	2	3	2	0	16
4	2	3	2	0	17
4	2	3	2	0	18
4	2	3	2	0	19
4	2	3	2	0	20
4	2	3	2	0	21
4	2	3	2	0	22
4	2	3	2	0	23
4	2	3	2	1	0
4	2	3	2	1	1
4	2	3	2	1	2
4	2	3	2	1	3
4	2	3	2	1	4
4	2	3	2	1	5
4	2	2	2	1	6
4	2	1	2	1	7
4	2	1	2	1	8
4	2	1	2	1	9
4	2	2	2	1	10
4	2	2	2	1	11
4	2	2	2	1	12
4	2	2	2	1	13
4	2	2	2	1	14
4	2	2	2	1	15
4	2	2	2	1	16
4	2	2	2	1	17
4	2	1	2	1	18
4	2	1	2	1	19
4	2	2	2	1	20
4	2	2	2	1	21
4	2	3	2	1	22
4	2	3	2	1	23
4	2	3	2	2	0
4	2	3	2	2	1
4	2	3	2	2	2
4	2	3	2	2	3
4	2	3	2	2	4
4	2	3	2	2	5
4	2	2	2	2	6
4	2	1	2	2	7
4	2	1	2	2	8
4	2	1	2	2	9
4	2	2	2	2	10
4	2	2	2	2	11
4	2	2	2	2	12
4	2	2	2	2	13
4	2	2	2	2	14
4	2	2	2	2	15
4	2	2	2	2	16
4	2	2	2	2	17
4	2	1	2	2	18
4	2	1	2	2	19
4	2	2	2	2	20
4	2	2	2	2	21
4	2	3	2	2	22
4	2	3	2	2	23
4	2	3	2	3	0
4	2	3	2	3	1
4	2	3	2	3	2
4	2	3	2	3	3
4	2	3	2	3	4
4	2	3	2	3	5
4	2	2	2	3	6
4	2	1	2	3	7
4	2	1	2	3	8
4	2	1	2	3	9
4	2	2	2	3	10
4	2	2	2	3	11
4	2	2	2	3	12
4	2	2	2	3	13
4	2	2	2	3	14
4	2	2	2	3	15
4	2	2	2	3	16
4	2	2	2	3	17
4	2	1	2	3	18
4	2	1	2	3	19
4	2	2	2	3	20
4	2	2	2	3	21
4	2	3	2	3	22
4	2	3	2	3	23
4	2	3	2	4	0
4	2	3	2	4	1
4	2	3	2	4	2
4	2	3	2	4	3
4	2	3	2	4	4
4	2	3	2	4	5
4	2	2	2	4	6
4	2	1	2	4	7
4	2	1	2	4	8
4	2	1	2	4	9
4	2	2	2	4	10
4	2	2	2	4	11
4	2	2	2	4	12
4	2	2	2	4	13
4	2	2	2	4	14
4	2	2	2	4	15
4	2	2	2	4	16
4	2	2	2	4	17
4	2	1	2	4	18
4	2	1	2	4	19
4	2	2	2	4	20
4	2	2	2	4	21
4	2	3	2	4	22
4	2	3	2	4	23
4	2	3	2	5	0
4	2	3	2	5	1
4	2	3	2	5	2
4	2	3	2	5	3
4	2	3	2	5	4
4	2	3	2	5	5
4	2	2	2	5	6
4	2	1	2	5	7
4	2	1	2	5	8
4	2	1	2	5	9
4	2	2	2	5	10
4	2	2	2	5	11
4	2	2	2	5	12
4	2	2	2	5	13
4	2	2	2	5	14
4	2	2	2	5	15
4	2	2	2	5	16
4	2	2	2	5	17
4	2	1	2	5	18
4	2	1	2	5	19
4	2	2	2	5	20
4	2	2	2	5	21
4	2	3	2	5	22
4	2	3	2	5	23
4	2	3	2	6	0
4	2	3	2	6	1
4	2	3	2	6	2
4	2	3	2	6	3
4	2	3	2	6	4
4	2	3	2	6	5
4	2	3	2	6	6
4	2	2	2	6	7
4	2	2	2	6	8
4	2	2	2	6	9
4	2	2	2	6	10
4	2	2	2	6	11
4	2	3	2	6	12
4	2	3	2	6	13
4	2	3	2	6	14
4	2	3	2	6	15
4	2	3	2	6	16
4	2	3	2	6	17
4	2	2	2	6	18
4	2	2	2	6	19
4	2	3	2	6	20
4	2	3	2	6	21
4	2	3	2	6	22
4	2	3	2	6	23
4	2	3	3	0	0
4	2	3	3	0	1
4	2	3	3	0	2
4	2	3	3	0	3
4	2	3	3	0	4
4	2	3	3	0	5
4	2	3	3	0	6
4	2	3	3	0	7
4	2	3	3	0	8
4	2	3	3	0	9
4	2	3	3	0	10
4	2	3	3	0	11
4	2	3	3	0	12
4	2	3	3	0	13
4	2	3	3	0	14
4	2	3	3	0	15
4	2	3	3	0	16
4	2	3	3	0	17
4	2	3	3	0	18
4	2	3	3	0	19
4	2	3	3	0	20
4	2	3	3	0	21
4	2	3	3	0	22
4	2	3	3	0	23
4	2	3	3	1	0
4	2	3	3	1	1
4	2	3	3	1	2
4	2	3	3	1	3
4	2	3	3	1	4
4	2	3	3	1	5
4	2	2	3	1	6
4	2	1	3	1	7
4	2	1	3	1	8
4	2	1	3	1	9
4	2	2	3	1	10
4	2	2	3	1	11
4	2	2	3	1	12
4	2	2	3	1	13
4	2	2	3	1	14
4	2	2	3	1	15
4	2	2	3	1	16
4	2	2	3	1	17
4	2	1	3	1	18
4	2	1	3	1	19
4	2	2	3	1	20
4	2	2	3	1	21
4	2	3	3	1	22
4	2	3	3	1	23
4	2	3	3	2	0
4	2	3	3	2	1
4	2	3	3	2	2
4	2	3	3	2	3
4	2	3	3	2	4
4	2	3	3	2	5
4	2	2	3	2	6
4	2	1	3	2	7
4	2	1	3	2	8
4	2	1	3	2	9
4	2	2	3	2	10
4	2	2	3	2	11
4	2	2	3	2	12
4	2	2	3	2	13
4	2	2	3	2	14
4	2	2	3	2	15
4	2	2	3	2	16
4	2	2	3	2	17
4	2	1	3	2	18
4	2	1	3	2	19
4	2	2	3	2	20
4	2	2	3	2	21
4	2	3	3	2	22
4	2	3	3	2	23
4	2	3	3	3	0
4	2	3	3	3	1
4	2	3	3	3	2
4	2	3	3	3	3
4	2	3	3	3	4
4	2	3	3	3	5
4	2	2	3	3	6
4	2	1	3	3	7
4	2	1	3	3	8
4	2	1	3	3	9
4	2	2	3	3	10
4	2	2	3	3	11
4	2	2	3	3	12
4	2	2	3	3	13
4	2	2	3	3	14
4	2	2	3	3	15
4	2	2	3	3	16
4	2	2	3	3	17
4	2	1	3	3	18
4	2	1	3	3	19
4	2	2	3	3	20
4	2	2	3	3	21
4	2	3	3	3	22
4	2	3	3	3	23
4	2	3	3	4	0
4	2	3	3	4	1
4	2	3	3	4	2
4	2	3	3	4	3
4	2	3	3	4	4
4	2	3	3	4	5
4	2	2	3	4	6
4	2	1	3	4	7
4	2	1	3	4	8
4	2	1	3	4	9
4	2	2	3	4	10
4	2	2	3	4	11
4	2	2	3	4	12
4	2	2	3	4	13
4	2	2	3	4	14
4	2	2	3	4	15
4	2	2	3	4	16
4	2	2	3	4	17
4	2	1	3	4	18
4	2	1	3	4	19
4	2	2	3	4	20
4	2	2	3	4	21
4	2	3	3	4	22
4	2	3	3	4	23
4	2	3	3	5	0
4	2	3	3	5	1
4	2	3	3	5	2
4	2	3	3	5	3
4	2	3	3	5	4
4	2	3	3	5	5
4	2	2	3	5	6
4	2	1	3	5	7
4	2	1	3	5	8
4	2	1	3	5	9
4	2	2	3	5	10
4	2	2	3	5	11
4	2	2	3	5	12
4	2	2	3	5	13
4	2	2	3	5	14
4	2	2	3	5	15
4	2	2	3	5	16
4	2	2	3	5	17
4	2	1	3	5	18
4	2	1	3	5	19
4	2	2	3	5	20
4	2	2	3	5	21
4	2	3	3	5	22
4	2	3	3	5	23
4	2	3	3	6	0
4	2	3	3	6	1
4	2	3	3	6	2
4	2	3	3	6	3
4	2	3	3	6	4
4	2	3	3	6	5
4	2	3	3	6	6
4	2	2	3	6	7
4	2	2	3	6	8
4	2	2	3	6	9
4	2	2	3	6	10
4	2	2	3	6	11
4	2	3	3	6	12
4	2	3	3	6	13
4	2	3	3	6	14
4	2	3	3	6	15
4	2	3	3	6	16
4	2	3	3	6	17
4	2	2	3	6	18
4	2	2	3	6	19
4	2	3	3	6	20
4	2	3	3	6	21
4	2	3	3	6	22
4	2	3	3	6	23
4	2	3	4	0	0
4	2	3	4	0	1
4	2	3	4	0	2
4	2	3	4	0	3
4	2	3	4	0	4
4	2	3	4	0	5
4	2	3	4	0	6
4	2	3	4	0	7
4	2	3	4	0	8
4	2	3	4	0	9
4	2	3	4	0	10
4	2	3	4	0	11
4	2	3	4	0	12
4	2	3	4	0	13
4	2	3	4	0	14
4	2	3	4	0	15
4	2	3	4	0	16
4	2	3	4	0	17
4	2	3	4	0	18
4	2	3	4	0	19
4	2	3	4	0	20
4	2	3	4	0	21
4	2	3	4	0	22
4	2	3	4	0	23
4	2	3	4	1	0
4	2	3	4	1	1
4	2	3	4	1	2
4	2	3	4	1	3
4	2	3	4	1	4
4	2	3	4	1	5
4	2	2	4	1	6
4	2	1	4	1	7
4	2	1	4	1	8
4	2	1	4	1	9
4	2	2	4	1	10
4	2	2	4	1	11
4	2	2	4	1	12
4	2	2	4	1	13
4	2	2	4	1	14
4	2	2	4	1	15
4	2	2	4	1	16
4	2	2	4	1	17
4	2	1	4	1	18
4	2	1	4	1	19
4	2	2	4	1	20
4	2	2	4	1	21
4	2	3	4	1	22
4	2	3	4	1	23
4	2	3	4	2	0
4	2	3	4	2	1
4	2	3	4	2	2
4	2	3	4	2	3
4	2	3	4	2	4
4	2	3	4	2	5
4	2	2	4	2	6
4	2	1	4	2	7
4	2	1	4	2	8
4	2	1	4	2	9
4	2	2	4	2	10
4	2	2	4	2	11
4	2	2	4	2	12
4	2	2	4	2	13
4	2	2	4	2	14
4	2	2	4	2	15
4	2	2	4	2	16
4	2	2	4	2	17
4	2	1	4	2	18
4	2	1	4	2	19
4	2	2	4	2	20
4	2	2	4	2	21
4	2	3	4	2	22
4	2	3	4	2	23
4	2	3	4	3	0
4	2	3	4	3	1
4	2	3	4	3	2
4	2	3	4	3	3
4	2	3	4	3	4
4	2	3	4	3	5
4	2	2	4	3	6
4	2	1	4	3	7
4	2	1	4	3	8
4	2	1	4	3	9
4	2	2	4	3	10
4	2	2	4	3	11
4	2	2	4	3	12
4	2	2	4	3	13
4	2	2	4	3	14
4	2	2	4	3	15
4	2	2	4	3	16
4	2	2	4	3	17
4	2	1	4	3	18
4	2	1	4	3	19
4	2	2	4	3	20
4	2	2	4	3	21
4	2	3	4	3	22
4	2	3	4	3	23
4	2	3	4	4	0
4	2	3	4	4	1
4	2	3	4	4	2
4	2	3	4	4	3
4	2	3	4	4	4
4	2	3	4	4	5
4	2	2	4	4	6
4	2	1	4	4	7
4	2	1	4	4	8
4	2	1	4	4	9
4	2	2	4	4	10
4	2	2	4	4	11
4	2	2	4	4	12
4	2	2	4	4	13
4	2	2	4	4	14
4	2	2	4	4	15
4	2	2	4	4	16
4	2	2	4	4	17
4	2	1	4	4	18
4	2	1	4	4	19
4	2	2	4	4	20
4	2	2	4	4	21
4	2	3	4	4	22
4	2	3	4	4	23
4	2	3	4	5	0
4	2	3	4	5	1
4	2	3	4	5	2
4	2	3	4	5	3
4	2	3	4	5	4
4	2	3	4	5	5
4	2	2	4	5	6
4	2	1	4	5	7
4	2	1	4	5	8
4	2	1	4	5	9
4	2	2	4	5	10
4	2	2	4	5	11
4	2	2	4	5	12
4	2	2	4	5	13
4	2	2	4	5	14
4	2	2	4	5	15
4	2	2	4	5	16
4	2	2	4	5	17
4	2	1	4	5	18
4	2	1	4	5	19
4	2	2	4	5	20
4	2	2	4	5	21
4	2	3	4	5	22
4	2	3	4	5	23
4	2	3	4	6	0
4	2	3	4	6	1
4	2	3	4	6	2
4	2	3	4	6	3
4	2	3	4	6	4
4	2	3	4	6	5
4	2	3	4	6	6
4	2	2	4	6	7
4	2	2	4	6	8
4	2	2	4	6	9
4	2	2	4	6	10
4	2	2	4	6	11
4	2	3	4	6	12
4	2	3	4	6	13
4	2	3	4	6	14
4	2	3	4	6	15
4	2	3	4	6	16
4	2	3	4	6	17
4	2	2	4	6	18
4	2	2	4	6	19
4	2	3	4	6	20
4	2	3	4	6	21
4	2	3	4	6	22
4	2	3	4	6	23
4	2	3	5	0	0
4	2	3	5	0	1
4	2	3	5	0	2
4	2	3	5	0	3
4	2	3	5	0	4
4	2	3	5	0	5
4	2	3	5	0	6
4	2	3	5	0	7
4	2	3	5	0	8
4	2	3	5	0	9
4	2	3	5	0	10
4	2	3	5	0	11
4	2	3	5	0	12
4	2	3	5	0	13
4	2	3	5	0	14
4	2	3	5	0	15
4	2	3	5	0	16
4	2	3	5	0	17
4	2	3	5	0	18
4	2	3	5	0	19
4	2	3	5	0	20
4	2	3	5	0	21
4	2	3	5	0	22
4	2	3	5	0	23
4	2	3	5	1	0
4	2	3	5	1	1
4	2	3	5	1	2
4	2	3	5	1	3
4	2	3	5	1	4
4	2	3	5	1	5
4	2	2	5	1	6
4	2	1	5	1	7
4	2	1	5	1	8
4	2	1	5	1	9
4	2	2	5	1	10
4	2	2	5	1	11
4	2	2	5	1	12
4	2	2	5	1	13
4	2	2	5	1	14
4	2	2	5	1	15
4	2	2	5	1	16
4	2	2	5	1	17
4	2	1	5	1	18
4	2	1	5	1	19
4	2	2	5	1	20
4	2	2	5	1	21
4	2	3	5	1	22
4	2	3	5	1	23
4	2	3	5	2	0
4	2	3	5	2	1
4	2	3	5	2	2
4	2	3	5	2	3
4	2	3	5	2	4
4	2	3	5	2	5
4	2	2	5	2	6
4	2	1	5	2	7
4	2	1	5	2	8
4	2	1	5	2	9
4	2	2	5	2	10
4	2	2	5	2	11
4	2	2	5	2	12
4	2	2	5	2	13
4	2	2	5	2	14
4	2	2	5	2	15
4	2	2	5	2	16
4	2	2	5	2	17
4	2	1	5	2	18
4	2	1	5	2	19
4	2	2	5	2	20
4	2	2	5	2	21
4	2	3	5	2	22
4	2	3	5	2	23
4	2	3	5	3	0
4	2	3	5	3	1
4	2	3	5	3	2
4	2	3	5	3	3
4	2	3	5	3	4
4	2	3	5	3	5
4	2	2	5	3	6
4	2	1	5	3	7
4	2	1	5	3	8
4	2	1	5	3	9
4	2	2	5	3	10
4	2	2	5	3	11
4	2	2	5	3	12
4	2	2	5	3	13
4	2	2	5	3	14
4	2	2	5	3	15
4	2	2	5	3	16
4	2	2	5	3	17
4	2	1	5	3	18
4	2	1	5	3	19
4	2	2	5	3	20
4	2	2	5	3	21
4	2	3	5	3	22
4	2	3	5	3	23
4	2	3	5	4	0
4	2	3	5	4	1
4	2	3	5	4	2
4	2	3	5	4	3
4	2	3	5	4	4
4	2	3	5	4	5
4	2	2	5	4	6
4	2	1	5	4	7
4	2	1	5	4	8
4	2	1	5	4	9
4	2	2	5	4	10
4	2	2	5	4	11
4	2	2	5	4	12
4	2	2	5	4	13
4	2	2	5	4	14
4	2	2	5	4	15
4	2	2	5	4	16
4	2	2	5	4	17
4	2	1	5	4	18
4	2	1	5	4	19
4	2	2	5	4	20
4	2	2	5	4	21
4	2	3	5	4	22
4	2	3	5	4	23
4	2	3	5	5	0
4	2	3	5	5	1
4	2	3	5	5	2
4	2	3	5	5	3
4	2	3	5	5	4
4	2	3	5	5	5
4	2	2	5	5	6
4	2	1	5	5	7
4	2	1	5	5	8
4	2	1	5	5	9
4	2	2	5	5	10
4	2	2	5	5	11
4	2	2	5	5	12
4	2	2	5	5	13
4	2	2	5	5	14
4	2	2	5	5	15
4	2	2	5	5	16
4	2	2	5	5	17
4	2	1	5	5	18
4	2	1	5	5	19
4	2	2	5	5	20
4	2	2	5	5	21
4	2	3	5	5	22
4	2	3	5	5	23
4	2	3	5	6	0
4	2	3	5	6	1
4	2	3	5	6	2
4	2	3	5	6	3
4	2	3	5	6	4
4	2	3	5	6	5
4	2	3	5	6	6
4	2	2	5	6	7
4	2	2	5	6	8
4	2	2	5	6	9
4	2	2	5	6	10
4	2	2	5	6	11
4	2	3	5	6	12
4	2	3	5	6	13
4	2	3	5	6	14
4	2	3	5	6	15
4	2	3	5	6	16
4	2	3	5	6	17
4	2	2	5	6	18
4	2	2	5	6	19
4	2	3	5	6	20
4	2	3	5	6	21
4	2	3	5	6	22
4	2	3	5	6	23
4	1	3	6	0	0
4	1	3	6	0	1
4	1	3	6	0	2
4	1	3	6	0	3
4	1	3	6	0	4
4	1	3	6	0	5
4	1	3	6	0	6
4	1	3	6	0	7
4	1	3	6	0	8
4	1	3	6	0	9
4	1	3	6	0	10
4	1	3	6	0	11
4	1	3	6	0	12
4	1	3	6	0	13
4	1	3	6	0	14
4	1	3	6	0	15
4	1	3	6	0	16
4	1	3	6	0	17
4	1	3	6	0	18
4	1	3	6	0	19
4	1	3	6	0	20
4	1	3	6	0	21
4	1	3	6	0	22
4	1	3	6	0	23
4	1	3	6	1	0
4	1	3	6	1	1
4	1	3	6	1	2
4	1	3	6	1	3
4	1	3	6	1	4
4	1	3	6	1	5
4	1	1	6	1	6
4	1	1	6	1	7
4	1	1	6	1	8
4	1	2	6	1	9
4	1	2	6	1	10
4	1	2	6	1	11
4	1	2	6	1	12
4	1	2	6	1	13
4	1	2	6	1	14
4	1	2	6	1	15
4	1	2	6	1	16
4	1	1	6	1	17
4	1	1	6	1	18
4	1	2	6	1	19
4	1	2	6	1	20
4	1	2	6	1	21
4	1	3	6	1	22
4	1	3	6	1	23
4	1	3	6	2	0
4	1	3	6	2	1
4	1	3	6	2	2
4	1	3	6	2	3
4	1	3	6	2	4
4	1	3	6	2	5
4	1	1	6	2	6
4	1	1	6	2	7
4	1	1	6	2	8
4	1	2	6	2	9
4	1	2	6	2	10
4	1	2	6	2	11
4	1	2	6	2	12
4	1	2	6	2	13
4	1	2	6	2	14
4	1	2	6	2	15
4	1	2	6	2	16
4	1	1	6	2	17
4	1	1	6	2	18
4	1	2	6	2	19
4	1	2	6	2	20
4	1	2	6	2	21
4	1	3	6	2	22
4	1	3	6	2	23
4	1	3	6	3	0
4	1	3	6	3	1
4	1	3	6	3	2
4	1	3	6	3	3
4	1	3	6	3	4
4	1	3	6	3	5
4	1	1	6	3	6
4	1	1	6	3	7
4	1	1	6	3	8
4	1	2	6	3	9
4	1	2	6	3	10
4	1	2	6	3	11
4	1	2	6	3	12
4	1	2	6	3	13
4	1	2	6	3	14
4	1	2	6	3	15
4	1	2	6	3	16
4	1	1	6	3	17
4	1	1	6	3	18
4	1	2	6	3	19
4	1	2	6	3	20
4	1	2	6	3	21
4	1	3	6	3	22
4	1	3	6	3	23
4	1	3	6	4	0
4	1	3	6	4	1
4	1	3	6	4	2
4	1	3	6	4	3
4	1	3	6	4	4
4	1	3	6	4	5
4	1	1	6	4	6
4	1	1	6	4	7
4	1	1	6	4	8
4	1	2	6	4	9
4	1	2	6	4	10
4	1	2	6	4	11
4	1	2	6	4	12
4	1	2	6	4	13
4	1	2	6	4	14
4	1	2	6	4	15
4	1	2	6	4	16
4	1	1	6	4	17
4	1	1	6	4	18
4	1	2	6	4	19
4	1	2	6	4	20
4	1	2	6	4	21
4	1	3	6	4	22
4	1	3	6	4	23
4	1	3	6	5	0
4	1	3	6	5	1
4	1	3	6	5	2
4	1	3	6	5	3
4	1	3	6	5	4
4	1	3	6	5	5
4	1	1	6	5	6
4	1	1	6	5	7
4	1	1	6	5	8
4	1	2	6	5	9
4	1	2	6	5	10
4	1	2	6	5	11
4	1	2	6	5	12
4	1	2	6	5	13
4	1	2	6	5	14
4	1	2	6	5	15
4	1	2	6	5	16
4	1	1	6	5	17
4	1	1	6	5	18
4	1	2	6	5	19
4	1	2	6	5	20
4	1	2	6	5	21
4	1	3	6	5	22
4	1	3	6	5	23
4	1	3	6	6	0
4	1	3	6	6	1
4	1	3	6	6	2
4	1	3	6	6	3
4	1	3	6	6	4
4	1	3	6	6	5
4	1	3	6	6	6
4	1	2	6	6	7
4	1	2	6	6	8
4	1	2	6	6	9
4	1	2	6	6	10
4	1	2	6	6	11
4	1	3	6	6	12
4	1	3	6	6	13
4	1	3	6	6	14
4	1	3	6	6	15
4	1	3	6	6	16
4	1	3	6	6	17
4	1	2	6	6	18
4	1	2	6	6	19
4	1	3	6	6	20
4	1	3	6	6	21
4	1	3	6	6	22
4	1	3	6	6	23
4	1	3	7	0	0
4	1	3	7	0	1
4	1	3	7	0	2
4	1	3	7	0	3
4	1	3	7	0	4
4	1	3	7	0	5
4	1	3	7	0	6
4	1	3	7	0	7
4	1	3	7	0	8
4	1	3	7	0	9
4	1	3	7	0	10
4	1	3	7	0	11
4	1	3	7	0	12
4	1	3	7	0	13
4	1	3	7	0	14
4	1	3	7	0	15
4	1	3	7	0	16
4	1	3	7	0	17
4	1	3	7	0	18
4	1	3	7	0	19
4	1	3	7	0	20
4	1	3	7	0	21
4	1	3	7	0	22
4	1	3	7	0	23
4	1	3	7	1	0
4	1	3	7	1	1
4	1	3	7	1	2
4	1	3	7	1	3
4	1	3	7	1	4
4	1	3	7	1	5
4	1	1	7	1	6
4	1	1	7	1	7
4	1	1	7	1	8
4	1	2	7	1	9
4	1	2	7	1	10
4	1	2	7	1	11
4	1	2	7	1	12
4	1	2	7	1	13
4	1	2	7	1	14
4	1	2	7	1	15
4	1	2	7	1	16
4	1	1	7	1	17
4	1	1	7	1	18
4	1	2	7	1	19
4	1	2	7	1	20
4	1	2	7	1	21
4	1	3	7	1	22
4	1	3	7	1	23
4	1	3	7	2	0
4	1	3	7	2	1
4	1	3	7	2	2
4	1	3	7	2	3
4	1	3	7	2	4
4	1	3	7	2	5
4	1	1	7	2	6
4	1	1	7	2	7
4	1	1	7	2	8
4	1	2	7	2	9
4	1	2	7	2	10
4	1	2	7	2	11
4	1	2	7	2	12
4	1	2	7	2	13
4	1	2	7	2	14
4	1	2	7	2	15
4	1	2	7	2	16
4	1	1	7	2	17
4	1	1	7	2	18
4	1	2	7	2	19
4	1	2	7	2	20
4	1	2	7	2	21
4	1	3	7	2	22
4	1	3	7	2	23
4	1	3	7	3	0
4	1	3	7	3	1
4	1	3	7	3	2
4	1	3	7	3	3
4	1	3	7	3	4
4	1	3	7	3	5
4	1	1	7	3	6
4	1	1	7	3	7
4	1	1	7	3	8
4	1	2	7	3	9
4	1	2	7	3	10
4	1	2	7	3	11
4	1	2	7	3	12
4	1	2	7	3	13
4	1	2	7	3	14
4	1	2	7	3	15
4	1	2	7	3	16
4	1	1	7	3	17
4	1	1	7	3	18
4	1	2	7	3	19
4	1	2	7	3	20
4	1	2	7	3	21
4	1	3	7	3	22
4	1	3	7	3	23
4	1	3	7	4	0
4	1	3	7	4	1
4	1	3	7	4	2
4	1	3	7	4	3
4	1	3	7	4	4
4	1	3	7	4	5
4	1	1	7	4	6
4	1	1	7	4	7
4	1	1	7	4	8
4	1	2	7	4	9
4	1	2	7	4	10
4	1	2	7	4	11
4	1	2	7	4	12
4	1	2	7	4	13
4	1	2	7	4	14
4	1	2	7	4	15
4	1	2	7	4	16
4	1	1	7	4	17
4	1	1	7	4	18
4	1	2	7	4	19
4	1	2	7	4	20
4	1	2	7	4	21
4	1	3	7	4	22
4	1	3	7	4	23
4	1	3	7	5	0
4	1	3	7	5	1
4	1	3	7	5	2
4	1	3	7	5	3
4	1	3	7	5	4
4	1	3	7	5	5
4	1	1	7	5	6
4	1	1	7	5	7
4	1	1	7	5	8
4	1	2	7	5	9
4	1	2	7	5	10
4	1	2	7	5	11
4	1	2	7	5	12
4	1	2	7	5	13
4	1	2	7	5	14
4	1	2	7	5	15
4	1	2	7	5	16
4	1	1	7	5	17
4	1	1	7	5	18
4	1	2	7	5	19
4	1	2	7	5	20
4	1	2	7	5	21
4	1	3	7	5	22
4	1	3	7	5	23
4	1	3	7	6	0
4	1	3	7	6	1
4	1	3	7	6	2
4	1	3	7	6	3
4	1	3	7	6	4
4	1	3	7	6	5
4	1	3	7	6	6
4	1	2	7	6	7
4	1	2	7	6	8
4	1	2	7	6	9
4	1	2	7	6	10
4	1	2	7	6	11
4	1	3	7	6	12
4	1	3	7	6	13
4	1	3	7	6	14
4	1	3	7	6	15
4	1	3	7	6	16
4	1	3	7	6	17
4	1	2	7	6	18
4	1	2	7	6	19
4	1	3	7	6	20
4	1	3	7	6	21
4	1	3	7	6	22
4	1	3	7	6	23
4	1	3	8	0	0
4	1	3	8	0	1
4	1	3	8	0	2
4	1	3	8	0	3
4	1	3	8	0	4
4	1	3	8	0	5
4	1	3	8	0	6
4	1	3	8	0	7
4	1	3	8	0	8
4	1	3	8	0	9
4	1	3	8	0	10
4	1	3	8	0	11
4	1	3	8	0	12
4	1	3	8	0	13
4	1	3	8	0	14
4	1	3	8	0	15
4	1	3	8	0	16
4	1	3	8	0	17
4	1	3	8	0	18
4	1	3	8	0	19
4	1	3	8	0	20
4	1	3	8	0	21
4	1	3	8	0	22
4	1	3	8	0	23
4	1	3	8	1	0
4	1	3	8	1	1
4	1	3	8	1	2
4	1	3	8	1	3
4	1	3	8	1	4
4	1	3	8	1	5
4	1	1	8	1	6
4	1	1	8	1	7
4	1	1	8	1	8
4	1	2	8	1	9
4	1	2	8	1	10
4	1	2	8	1	11
4	1	2	8	1	12
4	1	2	8	1	13
4	1	2	8	1	14
4	1	2	8	1	15
4	1	2	8	1	16
4	1	1	8	1	17
4	1	1	8	1	18
4	1	2	8	1	19
4	1	2	8	1	20
4	1	2	8	1	21
4	1	3	8	1	22
4	1	3	8	1	23
4	1	3	8	2	0
4	1	3	8	2	1
4	1	3	8	2	2
4	1	3	8	2	3
4	1	3	8	2	4
4	1	3	8	2	5
4	1	1	8	2	6
4	1	1	8	2	7
4	1	1	8	2	8
4	1	2	8	2	9
4	1	2	8	2	10
4	1	2	8	2	11
4	1	2	8	2	12
4	1	2	8	2	13
4	1	2	8	2	14
4	1	2	8	2	15
4	1	2	8	2	16
4	1	1	8	2	17
4	1	1	8	2	18
4	1	2	8	2	19
4	1	2	8	2	20
4	1	2	8	2	21
4	1	3	8	2	22
4	1	3	8	2	23
4	1	3	8	3	0
4	1	3	8	3	1
4	1	3	8	3	2
4	1	3	8	3	3
4	1	3	8	3	4
4	1	3	8	3	5
4	1	1	8	3	6
4	1	1	8	3	7
4	1	1	8	3	8
4	1	2	8	3	9
4	1	2	8	3	10
4	1	2	8	3	11
4	1	2	8	3	12
4	1	2	8	3	13
4	1	2	8	3	14
4	1	2	8	3	15
4	1	2	8	3	16
4	1	1	8	3	17
4	1	1	8	3	18
4	1	2	8	3	19
4	1	2	8	3	20
4	1	2	8	3	21
4	1	3	8	3	22
4	1	3	8	3	23
4	1	3	8	4	0
4	1	3	8	4	1
4	1	3	8	4	2
4	1	3	8	4	3
4	1	3	8	4	4
4	1	3	8	4	5
4	1	1	8	4	6
4	1	1	8	4	7
4	1	1	8	4	8
4	1	2	8	4	9
4	1	2	8	4	10
4	1	2	8	4	11
4	1	2	8	4	12
4	1	2	8	4	13
4	1	2	8	4	14
4	1	2	8	4	15
4	1	2	8	4	16
4	1	1	8	4	17
4	1	1	8	4	18
4	1	2	8	4	19
4	1	2	8	4	20
4	1	2	8	4	21
4	1	3	8	4	22
4	1	3	8	4	23
4	1	3	8	5	0
4	1	3	8	5	1
4	1	3	8	5	2
4	1	3	8	5	3
4	1	3	8	5	4
4	1	3	8	5	5
4	1	1	8	5	6
4	1	1	8	5	7
4	1	1	8	5	8
4	1	2	8	5	9
4	1	2	8	5	10
4	1	2	8	5	11
4	1	2	8	5	12
4	1	2	8	5	13
4	1	2	8	5	14
4	1	2	8	5	15
4	1	2	8	5	16
4	1	1	8	5	17
4	1	1	8	5	18
4	1	2	8	5	19
4	1	2	8	5	20
4	1	2	8	5	21
4	1	3	8	5	22
4	1	3	8	5	23
4	1	3	8	6	0
4	1	3	8	6	1
4	1	3	8	6	2
4	1	3	8	6	3
4	1	3	8	6	4
4	1	3	8	6	5
4	1	3	8	6	6
4	1	2	8	6	7
4	1	2	8	6	8
4	1	2	8	6	9
4	1	2	8	6	10
4	1	2	8	6	11
4	1	3	8	6	12
4	1	3	8	6	13
4	1	3	8	6	14
4	1	3	8	6	15
4	1	3	8	6	16
4	1	3	8	6	17
4	1	2	8	6	18
4	1	2	8	6	19
4	1	3	8	6	20
4	1	3	8	6	21
4	1	3	8	6	22
4	1	3	8	6	23
4	2	3	9	0	0
4	2	3	9	0	1
4	2	3	9	0	2
4	2	3	9	0	3
4	2	3	9	0	4
4	2	3	9	0	5
4	2	3	9	0	6
4	2	3	9	0	7
4	2	3	9	0	8
4	2	3	9	0	9
4	2	3	9	0	10
4	2	3	9	0	11
4	2	3	9	0	12
4	2	3	9	0	13
4	2	3	9	0	14
4	2	3	9	0	15
4	2	3	9	0	16
4	2	3	9	0	17
4	2	3	9	0	18
4	2	3	9	0	19
4	2	3	9	0	20
4	2	3	9	0	21
4	2	3	9	0	22
4	2	3	9	0	23
4	2	3	9	1	0
4	2	3	9	1	1
4	2	3	9	1	2
4	2	3	9	1	3
4	2	3	9	1	4
4	2	3	9	1	5
4	2	2	9	1	6
4	2	1	9	1	7
4	2	1	9	1	8
4	2	1	9	1	9
4	2	2	9	1	10
4	2	2	9	1	11
4	2	2	9	1	12
4	2	2	9	1	13
4	2	2	9	1	14
4	2	2	9	1	15
4	2	2	9	1	16
4	2	2	9	1	17
4	2	1	9	1	18
4	2	1	9	1	19
4	2	2	9	1	20
4	2	2	9	1	21
4	2	3	9	1	22
4	2	3	9	1	23
4	2	3	9	2	0
4	2	3	9	2	1
4	2	3	9	2	2
4	2	3	9	2	3
4	2	3	9	2	4
4	2	3	9	2	5
4	2	2	9	2	6
4	2	1	9	2	7
4	2	1	9	2	8
4	2	1	9	2	9
4	2	2	9	2	10
4	2	2	9	2	11
4	2	2	9	2	12
4	2	2	9	2	13
4	2	2	9	2	14
4	2	2	9	2	15
4	2	2	9	2	16
4	2	2	9	2	17
4	2	1	9	2	18
4	2	1	9	2	19
4	2	2	9	2	20
4	2	2	9	2	21
4	2	3	9	2	22
4	2	3	9	2	23
4	2	3	9	3	0
4	2	3	9	3	1
4	2	3	9	3	2
4	2	3	9	3	3
4	2	3	9	3	4
4	2	3	9	3	5
4	2	2	9	3	6
4	2	1	9	3	7
4	2	1	9	3	8
4	2	1	9	3	9
4	2	2	9	3	10
4	2	2	9	3	11
4	2	2	9	3	12
4	2	2	9	3	13
4	2	2	9	3	14
4	2	2	9	3	15
4	2	2	9	3	16
4	2	2	9	3	17
4	2	1	9	3	18
4	2	1	9	3	19
4	2	2	9	3	20
4	2	2	9	3	21
4	2	3	9	3	22
4	2	3	9	3	23
4	2	3	9	4	0
4	2	3	9	4	1
4	2	3	9	4	2
4	2	3	9	4	3
4	2	3	9	4	4
4	2	3	9	4	5
4	2	2	9	4	6
4	2	1	9	4	7
4	2	1	9	4	8
4	2	1	9	4	9
4	2	2	9	4	10
4	2	2	9	4	11
4	2	2	9	4	12
4	2	2	9	4	13
4	2	2	9	4	14
4	2	2	9	4	15
4	2	2	9	4	16
4	2	2	9	4	17
4	2	1	9	4	18
4	2	1	9	4	19
4	2	2	9	4	20
4	2	2	9	4	21
4	2	3	9	4	22
4	2	3	9	4	23
4	2	3	9	5	0
4	2	3	9	5	1
4	2	3	9	5	2
4	2	3	9	5	3
4	2	3	9	5	4
4	2	3	9	5	5
4	2	2	9	5	6
4	2	1	9	5	7
4	2	1	9	5	8
4	2	1	9	5	9
4	2	2	9	5	10
4	2	2	9	5	11
4	2	2	9	5	12
4	2	2	9	5	13
4	2	2	9	5	14
4	2	2	9	5	15
4	2	2	9	5	16
4	2	2	9	5	17
4	2	1	9	5	18
4	2	1	9	5	19
4	2	2	9	5	20
4	2	2	9	5	21
4	2	3	9	5	22
4	2	3	9	5	23
4	2	3	9	6	0
4	2	3	9	6	1
4	2	3	9	6	2
4	2	3	9	6	3
4	2	3	9	6	4
4	2	3	9	6	5
4	2	3	9	6	6
4	2	2	9	6	7
4	2	2	9	6	8
4	2	2	9	6	9
4	2	2	9	6	10
4	2	2	9	6	11
4	2	3	9	6	12
4	2	3	9	6	13
4	2	3	9	6	14
4	2	3	9	6	15
4	2	3	9	6	16
4	2	3	9	6	17
4	2	2	9	6	18
4	2	2	9	6	19
4	2	3	9	6	20
4	2	3	9	6	21
4	2	3	9	6	22
4	2	3	9	6	23
4	2	3	10	0	0
4	2	3	10	0	1
4	2	3	10	0	2
4	2	3	10	0	3
4	2	3	10	0	4
4	2	3	10	0	5
4	2	3	10	0	6
4	2	3	10	0	7
4	2	3	10	0	8
4	2	3	10	0	9
4	2	3	10	0	10
4	2	3	10	0	11
4	2	3	10	0	12
4	2	3	10	0	13
4	2	3	10	0	14
4	2	3	10	0	15
4	2	3	10	0	16
4	2	3	10	0	17
4	2	3	10	0	18
4	2	3	10	0	19
4	2	3	10	0	20
4	2	3	10	0	21
4	2	3	10	0	22
4	2	3	10	0	23
4	2	3	10	1	0
4	2	3	10	1	1
4	2	3	10	1	2
4	2	3	10	1	3
4	2	3	10	1	4
4	2	3	10	1	5
4	2	2	10	1	6
4	2	1	10	1	7
4	2	1	10	1	8
4	2	1	10	1	9
4	2	2	10	1	10
4	2	2	10	1	11
4	2	2	10	1	12
4	2	2	10	1	13
4	2	2	10	1	14
4	2	2	10	1	15
4	2	2	10	1	16
4	2	2	10	1	17
4	2	1	10	1	18
4	2	1	10	1	19
4	2	2	10	1	20
4	2	2	10	1	21
4	2	3	10	1	22
4	2	3	10	1	23
4	2	3	10	2	0
4	2	3	10	2	1
4	2	3	10	2	2
4	2	3	10	2	3
4	2	3	10	2	4
4	2	3	10	2	5
4	2	2	10	2	6
4	2	1	10	2	7
4	2	1	10	2	8
4	2	1	10	2	9
4	2	2	10	2	10
4	2	2	10	2	11
4	2	2	10	2	12
4	2	2	10	2	13
4	2	2	10	2	14
4	2	2	10	2	15
4	2	2	10	2	16
4	2	2	10	2	17
4	2	1	10	2	18
4	2	1	10	2	19
4	2	2	10	2	20
4	2	2	10	2	21
4	2	3	10	2	22
4	2	3	10	2	23
4	2	3	10	3	0
4	2	3	10	3	1
4	2	3	10	3	2
4	2	3	10	3	3
4	2	3	10	3	4
4	2	3	10	3	5
4	2	2	10	3	6
4	2	1	10	3	7
4	2	1	10	3	8
4	2	1	10	3	9
4	2	2	10	3	10
4	2	2	10	3	11
4	2	2	10	3	12
4	2	2	10	3	13
4	2	2	10	3	14
4	2	2	10	3	15
4	2	2	10	3	16
4	2	2	10	3	17
4	2	1	10	3	18
4	2	1	10	3	19
4	2	2	10	3	20
4	2	2	10	3	21
4	2	3	10	3	22
4	2	3	10	3	23
4	2	3	10	4	0
4	2	3	10	4	1
4	2	3	10	4	2
4	2	3	10	4	3
4	2	3	10	4	4
4	2	3	10	4	5
4	2	2	10	4	6
4	2	1	10	4	7
4	2	1	10	4	8
4	2	1	10	4	9
4	2	2	10	4	10
4	2	2	10	4	11
4	2	2	10	4	12
4	2	2	10	4	13
4	2	2	10	4	14
4	2	2	10	4	15
4	2	2	10	4	16
4	2	2	10	4	17
4	2	1	10	4	18
4	2	1	10	4	19
4	2	2	10	4	20
4	2	2	10	4	21
4	2	3	10	4	22
4	2	3	10	4	23
4	2	3	10	5	0
4	2	3	10	5	1
4	2	3	10	5	2
4	2	3	10	5	3
4	2	3	10	5	4
4	2	3	10	5	5
4	2	2	10	5	6
4	2	1	10	5	7
4	2	1	10	5	8
4	2	1	10	5	9
4	2	2	10	5	10
4	2	2	10	5	11
4	2	2	10	5	12
4	2	2	10	5	13
4	2	2	10	5	14
4	2	2	10	5	15
4	2	2	10	5	16
4	2	2	10	5	17
4	2	1	10	5	18
4	2	1	10	5	19
4	2	2	10	5	20
4	2	2	10	5	21
4	2	3	10	5	22
4	2	3	10	5	23
4	2	3	10	6	0
4	2	3	10	6	1
4	2	3	10	6	2
4	2	3	10	6	3
4	2	3	10	6	4
4	2	3	10	6	5
4	2	3	10	6	6
4	2	2	10	6	7
4	2	2	10	6	8
4	2	2	10	6	9
4	2	2	10	6	10
4	2	2	10	6	11
4	2	3	10	6	12
4	2	3	10	6	13
4	2	3	10	6	14
4	2	3	10	6	15
4	2	3	10	6	16
4	2	3	10	6	17
4	2	2	10	6	18
4	2	2	10	6	19
4	2	3	10	6	20
4	2	3	10	6	21
4	2	3	10	6	22
4	2	3	10	6	23
4	2	3	11	0	0
4	2	3	11	0	1
4	2	3	11	0	2
4	2	3	11	0	3
4	2	3	11	0	4
4	2	3	11	0	5
4	2	3	11	0	6
4	2	3	11	0	7
4	2	3	11	0	8
4	2	3	11	0	9
4	2	3	11	0	10
4	2	3	11	0	11
4	2	3	11	0	12
4	2	3	11	0	13
4	2	3	11	0	14
4	2	3	11	0	15
4	2	3	11	0	16
4	2	3	11	0	17
4	2	3	11	0	18
4	2	3	11	0	19
4	2	3	11	0	20
4	2	3	11	0	21
4	2	3	11	0	22
4	2	3	11	0	23
4	2	3	11	1	0
4	2	3	11	1	1
4	2	3	11	1	2
4	2	3	11	1	3
4	2	3	11	1	4
4	2	3	11	1	5
4	2	2	11	1	6
4	2	1	11	1	7
4	2	1	11	1	8
4	2	1	11	1	9
4	2	2	11	1	10
4	2	2	11	1	11
4	2	2	11	1	12
4	2	2	11	1	13
4	2	2	11	1	14
4	2	2	11	1	15
4	2	2	11	1	16
4	2	2	11	1	17
4	2	1	11	1	18
4	2	1	11	1	19
4	2	2	11	1	20
4	2	2	11	1	21
4	2	3	11	1	22
4	2	3	11	1	23
4	2	3	11	2	0
4	2	3	11	2	1
4	2	3	11	2	2
4	2	3	11	2	3
4	2	3	11	2	4
4	2	3	11	2	5
4	2	2	11	2	6
4	2	1	11	2	7
4	2	1	11	2	8
4	2	1	11	2	9
4	2	2	11	2	10
4	2	2	11	2	11
4	2	2	11	2	12
4	2	2	11	2	13
4	2	2	11	2	14
4	2	2	11	2	15
4	2	2	11	2	16
4	2	2	11	2	17
4	2	1	11	2	18
4	2	1	11	2	19
4	2	2	11	2	20
4	2	2	11	2	21
4	2	3	11	2	22
4	2	3	11	2	23
4	2	3	11	3	0
4	2	3	11	3	1
4	2	3	11	3	2
4	2	3	11	3	3
4	2	3	11	3	4
4	2	3	11	3	5
4	2	2	11	3	6
4	2	1	11	3	7
4	2	1	11	3	8
4	2	1	11	3	9
4	2	2	11	3	10
4	2	2	11	3	11
4	2	2	11	3	12
4	2	2	11	3	13
4	2	2	11	3	14
4	2	2	11	3	15
4	2	2	11	3	16
4	2	2	11	3	17
4	2	1	11	3	18
4	2	1	11	3	19
4	2	2	11	3	20
4	2	2	11	3	21
4	2	3	11	3	22
4	2	3	11	3	23
4	2	3	11	4	0
4	2	3	11	4	1
4	2	3	11	4	2
4	2	3	11	4	3
4	2	3	11	4	4
4	2	3	11	4	5
4	2	2	11	4	6
4	2	1	11	4	7
4	2	1	11	4	8
4	2	1	11	4	9
4	2	2	11	4	10
4	2	2	11	4	11
4	2	2	11	4	12
4	2	2	11	4	13
4	2	2	11	4	14
4	2	2	11	4	15
4	2	2	11	4	16
4	2	2	11	4	17
4	2	1	11	4	18
4	2	1	11	4	19
4	2	2	11	4	20
4	2	2	11	4	21
4	2	3	11	4	22
4	2	3	11	4	23
4	2	3	11	5	0
4	2	3	11	5	1
4	2	3	11	5	2
4	2	3	11	5	3
4	2	3	11	5	4
4	2	3	11	5	5
4	2	2	11	5	6
4	2	1	11	5	7
4	2	1	11	5	8
4	2	1	11	5	9
4	2	2	11	5	10
4	2	2	11	5	11
4	2	2	11	5	12
4	2	2	11	5	13
4	2	2	11	5	14
4	2	2	11	5	15
4	2	2	11	5	16
4	2	2	11	5	17
4	2	1	11	5	18
4	2	1	11	5	19
4	2	2	11	5	20
4	2	2	11	5	21
4	2	3	11	5	22
4	2	3	11	5	23
4	2	3	11	6	0
4	2	3	11	6	1
4	2	3	11	6	2
4	2	3	11	6	3
4	2	3	11	6	4
4	2	3	11	6	5
4	2	3	11	6	6
4	2	2	11	6	7
4	2	2	11	6	8
4	2	2	11	6	9
4	2	2	11	6	10
4	2	2	11	6	11
4	2	3	11	6	12
4	2	3	11	6	13
4	2	3	11	6	14
4	2	3	11	6	15
4	2	3	11	6	16
4	2	3	11	6	17
4	2	2	11	6	18
4	2	2	11	6	19
4	2	3	11	6	20
4	2	3	11	6	21
4	2	3	11	6	22
4	2	3	11	6	23
4	2	3	12	0	0
4	2	3	12	0	1
4	2	3	12	0	2
4	2	3	12	0	3
4	2	3	12	0	4
4	2	3	12	0	5
4	2	3	12	0	6
4	2	3	12	0	7
4	2	3	12	0	8
4	2	3	12	0	9
4	2	3	12	0	10
4	2	3	12	0	11
4	2	3	12	0	12
4	2	3	12	0	13
4	2	3	12	0	14
4	2	3	12	0	15
4	2	3	12	0	16
4	2	3	12	0	17
4	2	3	12	0	18
4	2	3	12	0	19
4	2	3	12	0	20
4	2	3	12	0	21
4	2	3	12	0	22
4	2	3	12	0	23
4	2	3	12	1	0
4	2	3	12	1	1
4	2	3	12	1	2
4	2	3	12	1	3
4	2	3	12	1	4
4	2	3	12	1	5
4	2	2	12	1	6
4	2	1	12	1	7
4	2	1	12	1	8
4	2	1	12	1	9
4	2	2	12	1	10
4	2	2	12	1	11
4	2	2	12	1	12
4	2	2	12	1	13
4	2	2	12	1	14
4	2	2	12	1	15
4	2	2	12	1	16
4	2	2	12	1	17
4	2	1	12	1	18
4	2	1	12	1	19
4	2	2	12	1	20
4	2	2	12	1	21
4	2	3	12	1	22
4	2	3	12	1	23
4	2	3	12	2	0
4	2	3	12	2	1
4	2	3	12	2	2
4	2	3	12	2	3
4	2	3	12	2	4
4	2	3	12	2	5
4	2	2	12	2	6
4	2	1	12	2	7
4	2	1	12	2	8
4	2	1	12	2	9
4	2	2	12	2	10
4	2	2	12	2	11
4	2	2	12	2	12
4	2	2	12	2	13
4	2	2	12	2	14
4	2	2	12	2	15
4	2	2	12	2	16
4	2	2	12	2	17
4	2	1	12	2	18
4	2	1	12	2	19
4	2	2	12	2	20
4	2	2	12	2	21
4	2	3	12	2	22
4	2	3	12	2	23
4	2	3	12	3	0
4	2	3	12	3	1
4	2	3	12	3	2
4	2	3	12	3	3
4	2	3	12	3	4
4	2	3	12	3	5
4	2	2	12	3	6
4	2	1	12	3	7
4	2	1	12	3	8
4	2	1	12	3	9
4	2	2	12	3	10
4	2	2	12	3	11
4	2	2	12	3	12
4	2	2	12	3	13
4	2	2	12	3	14
4	2	2	12	3	15
4	2	2	12	3	16
4	2	2	12	3	17
4	2	1	12	3	18
4	2	1	12	3	19
4	2	2	12	3	20
4	2	2	12	3	21
4	2	3	12	3	22
4	2	3	12	3	23
4	2	3	12	4	0
4	2	3	12	4	1
4	2	3	12	4	2
4	2	3	12	4	3
4	2	3	12	4	4
4	2	3	12	4	5
4	2	2	12	4	6
4	2	1	12	4	7
4	2	1	12	4	8
4	2	1	12	4	9
4	2	2	12	4	10
4	2	2	12	4	11
4	2	2	12	4	12
4	2	2	12	4	13
4	2	2	12	4	14
4	2	2	12	4	15
4	2	2	12	4	16
4	2	2	12	4	17
4	2	1	12	4	18
4	2	1	12	4	19
4	2	2	12	4	20
4	2	2	12	4	21
4	2	3	12	4	22
4	2	3	12	4	23
4	2	3	12	5	0
4	2	3	12	5	1
4	2	3	12	5	2
4	2	3	12	5	3
4	2	3	12	5	4
4	2	3	12	5	5
4	2	2	12	5	6
4	2	1	12	5	7
4	2	1	12	5	8
4	2	1	12	5	9
4	2	2	12	5	10
4	2	2	12	5	11
4	2	2	12	5	12
4	2	2	12	5	13
4	2	2	12	5	14
4	2	2	12	5	15
4	2	2	12	5	16
4	2	2	12	5	17
4	2	1	12	5	18
4	2	1	12	5	19
4	2	2	12	5	20
4	2	2	12	5	21
4	2	3	12	5	22
4	2	3	12	5	23
4	2	3	12	6	0
4	2	3	12	6	1
4	2	3	12	6	2
4	2	3	12	6	3
4	2	3	12	6	4
4	2	3	12	6	5
4	2	3	12	6	6
4	2	2	12	6	7
4	2	2	12	6	8
4	2	2	12	6	9
4	2	2	12	6	10
4	2	2	12	6	11
4	2	3	12	6	12
4	2	3	12	6	13
4	2	3	12	6	14
4	2	3	12	6	15
4	2	3	12	6	16
4	2	3	12	6	17
4	2	2	12	6	18
4	2	2	12	6	19
4	2	3	12	6	20
4	2	3	12	6	21
4	2	3	12	6	22
4	2	3	12	6	23
5	2	3	1	0	0
5	2	3	1	0	1
5	2	3	1	0	2
5	2	3	1	0	3
5	2	3	1	0	4
5	2	3	1	0	5
5	2	3	1	0	6
5	2	3	1	0	7
5	2	3	1	0	8
5	2	3	1	0	9
5	2	3	1	0	10
5	2	3	1	0	11
5	2	3	1	0	12
5	2	3	1	0	13
5	2	3	1	0	14
5	2	3	1	0	15
5	2	3	1	0	16
5	2	3	1	0	17
5	2	2	1	0	18
5	2	2	1	0	19
5	2	3	1	0	20
5	2	3	1	0	21
5	2	3	1	0	22
5	2	3	1	0	23
5	2	3	1	1	0
5	2	3	1	1	1
5	2	3	1	1	2
5	2	3	1	1	3
5	2	3	1	1	4
5	2	3	1	1	5
5	2	2	1	1	6
5	2	1	1	1	7
5	2	1	1	1	8
5	2	2	1	1	9
5	2	2	1	1	10
5	2	2	1	1	11
5	2	2	1	1	12
5	2	2	1	1	13
5	2	2	1	1	14
5	2	2	1	1	15
5	2	2	1	1	16
5	2	2	1	1	17
5	2	1	1	1	18
5	2	1	1	1	19
5	2	1	1	1	20
5	2	2	1	1	21
5	2	3	1	1	22
5	2	3	1	1	23
5	2	3	1	2	0
5	2	3	1	2	1
5	2	3	1	2	2
5	2	3	1	2	3
5	2	3	1	2	4
5	2	3	1	2	5
5	2	2	1	2	6
5	2	1	1	2	7
5	2	1	1	2	8
5	2	2	1	2	9
5	2	2	1	2	10
5	2	2	1	2	11
5	2	2	1	2	12
5	2	2	1	2	13
5	2	2	1	2	14
5	2	2	1	2	15
5	2	2	1	2	16
5	2	2	1	2	17
5	2	1	1	2	18
5	2	1	1	2	19
5	2	1	1	2	20
5	2	2	1	2	21
5	2	3	1	2	22
5	2	3	1	2	23
5	2	3	1	3	0
5	2	3	1	3	1
5	2	3	1	3	2
5	2	3	1	3	3
5	2	3	1	3	4
5	2	3	1	3	5
5	2	2	1	3	6
5	2	1	1	3	7
5	2	1	1	3	8
5	2	2	1	3	9
5	2	2	1	3	10
5	2	2	1	3	11
5	2	2	1	3	12
5	2	2	1	3	13
5	2	2	1	3	14
5	2	2	1	3	15
5	2	2	1	3	16
5	2	2	1	3	17
5	2	1	1	3	18
5	2	1	1	3	19
5	2	1	1	3	20
5	2	2	1	3	21
5	2	3	1	3	22
5	2	3	1	3	23
5	2	3	1	4	0
5	2	3	1	4	1
5	2	3	1	4	2
5	2	3	1	4	3
5	2	3	1	4	4
5	2	3	1	4	5
5	2	2	1	4	6
5	2	1	1	4	7
5	2	1	1	4	8
5	2	2	1	4	9
5	2	2	1	4	10
5	2	2	1	4	11
5	2	2	1	4	12
5	2	2	1	4	13
5	2	2	1	4	14
5	2	2	1	4	15
5	2	2	1	4	16
5	2	2	1	4	17
5	2	1	1	4	18
5	2	1	1	4	19
5	2	1	1	4	20
5	2	2	1	4	21
5	2	3	1	4	22
5	2	3	1	4	23
5	2	3	1	5	0
5	2	3	1	5	1
5	2	3	1	5	2
5	2	3	1	5	3
5	2	3	1	5	4
5	2	3	1	5	5
5	2	2	1	5	6
5	2	1	1	5	7
5	2	1	1	5	8
5	2	2	1	5	9
5	2	2	1	5	10
5	2	2	1	5	11
5	2	2	1	5	12
5	2	2	1	5	13
5	2	2	1	5	14
5	2	2	1	5	15
5	2	2	1	5	16
5	2	2	1	5	17
5	2	1	1	5	18
5	2	1	1	5	19
5	2	1	1	5	20
5	2	2	1	5	21
5	2	3	1	5	22
5	2	3	1	5	23
5	2	3	1	6	0
5	2	3	1	6	1
5	2	3	1	6	2
5	2	3	1	6	3
5	2	3	1	6	4
5	2	3	1	6	5
5	2	3	1	6	6
5	2	2	1	6	7
5	2	2	1	6	8
5	2	2	1	6	9
5	2	2	1	6	10
5	2	2	1	6	11
5	2	3	1	6	12
5	2	3	1	6	13
5	2	3	1	6	14
5	2	3	1	6	15
5	2	3	1	6	16
5	2	3	1	6	17
5	2	2	1	6	18
5	2	2	1	6	19
5	2	3	1	6	20
5	2	3	1	6	21
5	2	3	1	6	22
5	2	3	1	6	23
5	2	3	2	0	0
5	2	3	2	0	1
5	2	3	2	0	2
5	2	3	2	0	3
5	2	3	2	0	4
5	2	3	2	0	5
5	2	3	2	0	6
5	2	3	2	0	7
5	2	3	2	0	8
5	2	3	2	0	9
5	2	3	2	0	10
5	2	3	2	0	11
5	2	3	2	0	12
5	2	3	2	0	13
5	2	3	2	0	14
5	2	3	2	0	15
5	2	3	2	0	16
5	2	3	2	0	17
5	2	2	2	0	18
5	2	2	2	0	19
5	2	3	2	0	20
5	2	3	2	0	21
5	2	3	2	0	22
5	2	3	2	0	23
5	2	3	2	1	0
5	2	3	2	1	1
5	2	3	2	1	2
5	2	3	2	1	3
5	2	3	2	1	4
5	2	3	2	1	5
5	2	2	2	1	6
5	2	1	2	1	7
5	2	1	2	1	8
5	2	2	2	1	9
5	2	2	2	1	10
5	2	2	2	1	11
5	2	2	2	1	12
5	2	2	2	1	13
5	2	2	2	1	14
5	2	2	2	1	15
5	2	2	2	1	16
5	2	2	2	1	17
5	2	1	2	1	18
5	2	1	2	1	19
5	2	1	2	1	20
5	2	2	2	1	21
5	2	3	2	1	22
5	2	3	2	1	23
5	2	3	2	2	0
5	2	3	2	2	1
5	2	3	2	2	2
5	2	3	2	2	3
5	2	3	2	2	4
5	2	3	2	2	5
5	2	2	2	2	6
5	2	1	2	2	7
5	2	1	2	2	8
5	2	2	2	2	9
5	2	2	2	2	10
5	2	2	2	2	11
5	2	2	2	2	12
5	2	2	2	2	13
5	2	2	2	2	14
5	2	2	2	2	15
5	2	2	2	2	16
5	2	2	2	2	17
5	2	1	2	2	18
5	2	1	2	2	19
5	2	1	2	2	20
5	2	2	2	2	21
5	2	3	2	2	22
5	2	3	2	2	23
5	2	3	2	3	0
5	2	3	2	3	1
5	2	3	2	3	2
5	2	3	2	3	3
5	2	3	2	3	4
5	2	3	2	3	5
5	2	2	2	3	6
5	2	1	2	3	7
5	2	1	2	3	8
5	2	2	2	3	9
5	2	2	2	3	10
5	2	2	2	3	11
5	2	2	2	3	12
5	2	2	2	3	13
5	2	2	2	3	14
5	2	2	2	3	15
5	2	2	2	3	16
5	2	2	2	3	17
5	2	1	2	3	18
5	2	1	2	3	19
5	2	1	2	3	20
5	2	2	2	3	21
5	2	3	2	3	22
5	2	3	2	3	23
5	2	3	2	4	0
5	2	3	2	4	1
5	2	3	2	4	2
5	2	3	2	4	3
5	2	3	2	4	4
5	2	3	2	4	5
5	2	2	2	4	6
5	2	1	2	4	7
5	2	1	2	4	8
5	2	2	2	4	9
5	2	2	2	4	10
5	2	2	2	4	11
5	2	2	2	4	12
5	2	2	2	4	13
5	2	2	2	4	14
5	2	2	2	4	15
5	2	2	2	4	16
5	2	2	2	4	17
5	2	1	2	4	18
5	2	1	2	4	19
5	2	1	2	4	20
5	2	2	2	4	21
5	2	3	2	4	22
5	2	3	2	4	23
5	2	3	2	5	0
5	2	3	2	5	1
5	2	3	2	5	2
5	2	3	2	5	3
5	2	3	2	5	4
5	2	3	2	5	5
5	2	2	2	5	6
5	2	1	2	5	7
5	2	1	2	5	8
5	2	2	2	5	9
5	2	2	2	5	10
5	2	2	2	5	11
5	2	2	2	5	12
5	2	2	2	5	13
5	2	2	2	5	14
5	2	2	2	5	15
5	2	2	2	5	16
5	2	2	2	5	17
5	2	1	2	5	18
5	2	1	2	5	19
5	2	1	2	5	20
5	2	2	2	5	21
5	2	3	2	5	22
5	2	3	2	5	23
5	2	3	2	6	0
5	2	3	2	6	1
5	2	3	2	6	2
5	2	3	2	6	3
5	2	3	2	6	4
5	2	3	2	6	5
5	2	3	2	6	6
5	2	2	2	6	7
5	2	2	2	6	8
5	2	2	2	6	9
5	2	2	2	6	10
5	2	2	2	6	11
5	2	3	2	6	12
5	2	3	2	6	13
5	2	3	2	6	14
5	2	3	2	6	15
5	2	3	2	6	16
5	2	3	2	6	17
5	2	2	2	6	18
5	2	2	2	6	19
5	2	3	2	6	20
5	2	3	2	6	21
5	2	3	2	6	22
5	2	3	2	6	23
5	2	3	3	0	0
5	2	3	3	0	1
5	2	3	3	0	2
5	2	3	3	0	3
5	2	3	3	0	4
5	2	3	3	0	5
5	2	3	3	0	6
5	2	3	3	0	7
5	2	3	3	0	8
5	2	3	3	0	9
5	2	3	3	0	10
5	2	3	3	0	11
5	2	3	3	0	12
5	2	3	3	0	13
5	2	3	3	0	14
5	2	3	3	0	15
5	2	3	3	0	16
5	2	3	3	0	17
5	2	2	3	0	18
5	2	2	3	0	19
5	2	3	3	0	20
5	2	3	3	0	21
5	2	3	3	0	22
5	2	3	3	0	23
5	2	3	3	1	0
5	2	3	3	1	1
5	2	3	3	1	2
5	2	3	3	1	3
5	2	3	3	1	4
5	2	3	3	1	5
5	2	2	3	1	6
5	2	1	3	1	7
5	2	1	3	1	8
5	2	2	3	1	9
5	2	2	3	1	10
5	2	2	3	1	11
5	2	2	3	1	12
5	2	2	3	1	13
5	2	2	3	1	14
5	2	2	3	1	15
5	2	2	3	1	16
5	2	2	3	1	17
5	2	1	3	1	18
5	2	1	3	1	19
5	2	1	3	1	20
5	2	2	3	1	21
5	2	3	3	1	22
5	2	3	3	1	23
5	2	3	3	2	0
5	2	3	3	2	1
5	2	3	3	2	2
5	2	3	3	2	3
5	2	3	3	2	4
5	2	3	3	2	5
5	2	2	3	2	6
5	2	1	3	2	7
5	2	1	3	2	8
5	2	2	3	2	9
5	2	2	3	2	10
5	2	2	3	2	11
5	2	2	3	2	12
5	2	2	3	2	13
5	2	2	3	2	14
5	2	2	3	2	15
5	2	2	3	2	16
5	2	2	3	2	17
5	2	1	3	2	18
5	2	1	3	2	19
5	2	1	3	2	20
5	2	2	3	2	21
5	2	3	3	2	22
5	2	3	3	2	23
5	2	3	3	3	0
5	2	3	3	3	1
5	2	3	3	3	2
5	2	3	3	3	3
5	2	3	3	3	4
5	2	3	3	3	5
5	2	2	3	3	6
5	2	1	3	3	7
5	2	1	3	3	8
5	2	2	3	3	9
5	2	2	3	3	10
5	2	2	3	3	11
5	2	2	3	3	12
5	2	2	3	3	13
5	2	2	3	3	14
5	2	2	3	3	15
5	2	2	3	3	16
5	2	2	3	3	17
5	2	1	3	3	18
5	2	1	3	3	19
5	2	1	3	3	20
5	2	2	3	3	21
5	2	3	3	3	22
5	2	3	3	3	23
5	2	3	3	4	0
5	2	3	3	4	1
5	2	3	3	4	2
5	2	3	3	4	3
5	2	3	3	4	4
5	2	3	3	4	5
5	2	2	3	4	6
5	2	1	3	4	7
5	2	1	3	4	8
5	2	2	3	4	9
5	2	2	3	4	10
5	2	2	3	4	11
5	2	2	3	4	12
5	2	2	3	4	13
5	2	2	3	4	14
5	2	2	3	4	15
5	2	2	3	4	16
5	2	2	3	4	17
5	2	1	3	4	18
5	2	1	3	4	19
5	2	1	3	4	20
5	2	2	3	4	21
5	2	3	3	4	22
5	2	3	3	4	23
5	2	3	3	5	0
5	2	3	3	5	1
5	2	3	3	5	2
5	2	3	3	5	3
5	2	3	3	5	4
5	2	3	3	5	5
5	2	2	3	5	6
5	2	1	3	5	7
5	2	1	3	5	8
5	2	2	3	5	9
5	2	2	3	5	10
5	2	2	3	5	11
5	2	2	3	5	12
5	2	2	3	5	13
5	2	2	3	5	14
5	2	2	3	5	15
5	2	2	3	5	16
5	2	2	3	5	17
5	2	1	3	5	18
5	2	1	3	5	19
5	2	1	3	5	20
5	2	2	3	5	21
5	2	3	3	5	22
5	2	3	3	5	23
5	2	3	3	6	0
5	2	3	3	6	1
5	2	3	3	6	2
5	2	3	3	6	3
5	2	3	3	6	4
5	2	3	3	6	5
5	2	3	3	6	6
5	2	2	3	6	7
5	2	2	3	6	8
5	2	2	3	6	9
5	2	2	3	6	10
5	2	2	3	6	11
5	2	3	3	6	12
5	2	3	3	6	13
5	2	3	3	6	14
5	2	3	3	6	15
5	2	3	3	6	16
5	2	3	3	6	17
5	2	2	3	6	18
5	2	2	3	6	19
5	2	3	3	6	20
5	2	3	3	6	21
5	2	3	3	6	22
5	2	3	3	6	23
5	2	3	4	0	0
5	2	3	4	0	1
5	2	3	4	0	2
5	2	3	4	0	3
5	2	3	4	0	4
5	2	3	4	0	5
5	2	3	4	0	6
5	2	3	4	0	7
5	2	3	4	0	8
5	2	3	4	0	9
5	2	3	4	0	10
5	2	3	4	0	11
5	2	3	4	0	12
5	2	3	4	0	13
5	2	3	4	0	14
5	2	3	4	0	15
5	2	3	4	0	16
5	2	3	4	0	17
5	2	2	4	0	18
5	2	2	4	0	19
5	2	3	4	0	20
5	2	3	4	0	21
5	2	3	4	0	22
5	2	3	4	0	23
5	2	3	4	1	0
5	2	3	4	1	1
5	2	3	4	1	2
5	2	3	4	1	3
5	2	3	4	1	4
5	2	3	4	1	5
5	2	2	4	1	6
5	2	1	4	1	7
5	2	1	4	1	8
5	2	2	4	1	9
5	2	2	4	1	10
5	2	2	4	1	11
5	2	2	4	1	12
5	2	2	4	1	13
5	2	2	4	1	14
5	2	2	4	1	15
5	2	2	4	1	16
5	2	2	4	1	17
5	2	1	4	1	18
5	2	1	4	1	19
5	2	1	4	1	20
5	2	2	4	1	21
5	2	3	4	1	22
5	2	3	4	1	23
5	2	3	4	2	0
5	2	3	4	2	1
5	2	3	4	2	2
5	2	3	4	2	3
5	2	3	4	2	4
5	2	3	4	2	5
5	2	2	4	2	6
5	2	1	4	2	7
5	2	1	4	2	8
5	2	2	4	2	9
5	2	2	4	2	10
5	2	2	4	2	11
5	2	2	4	2	12
5	2	2	4	2	13
5	2	2	4	2	14
5	2	2	4	2	15
5	2	2	4	2	16
5	2	2	4	2	17
5	2	1	4	2	18
5	2	1	4	2	19
5	2	1	4	2	20
5	2	2	4	2	21
5	2	3	4	2	22
5	2	3	4	2	23
5	2	3	4	3	0
5	2	3	4	3	1
5	2	3	4	3	2
5	2	3	4	3	3
5	2	3	4	3	4
5	2	3	4	3	5
5	2	2	4	3	6
5	2	1	4	3	7
5	2	1	4	3	8
5	2	2	4	3	9
5	2	2	4	3	10
5	2	2	4	3	11
5	2	2	4	3	12
5	2	2	4	3	13
5	2	2	4	3	14
5	2	2	4	3	15
5	2	2	4	3	16
5	2	2	4	3	17
5	2	1	4	3	18
5	2	1	4	3	19
5	2	1	4	3	20
5	2	2	4	3	21
5	2	3	4	3	22
5	2	3	4	3	23
5	2	3	4	4	0
5	2	3	4	4	1
5	2	3	4	4	2
5	2	3	4	4	3
5	2	3	4	4	4
5	2	3	4	4	5
5	2	2	4	4	6
5	2	1	4	4	7
5	2	1	4	4	8
5	2	2	4	4	9
5	2	2	4	4	10
5	2	2	4	4	11
5	2	2	4	4	12
5	2	2	4	4	13
5	2	2	4	4	14
5	2	2	4	4	15
5	2	2	4	4	16
5	2	2	4	4	17
5	2	1	4	4	18
5	2	1	4	4	19
5	2	1	4	4	20
5	2	2	4	4	21
5	2	3	4	4	22
5	2	3	4	4	23
5	2	3	4	5	0
5	2	3	4	5	1
5	2	3	4	5	2
5	2	3	4	5	3
5	2	3	4	5	4
5	2	3	4	5	5
5	2	2	4	5	6
5	2	1	4	5	7
5	2	1	4	5	8
5	2	2	4	5	9
5	2	2	4	5	10
5	2	2	4	5	11
5	2	2	4	5	12
5	2	2	4	5	13
5	2	2	4	5	14
5	2	2	4	5	15
5	2	2	4	5	16
5	2	2	4	5	17
5	2	1	4	5	18
5	2	1	4	5	19
5	2	1	4	5	20
5	2	2	4	5	21
5	2	3	4	5	22
5	2	3	4	5	23
5	2	3	4	6	0
5	2	3	4	6	1
5	2	3	4	6	2
5	2	3	4	6	3
5	2	3	4	6	4
5	2	3	4	6	5
5	2	3	4	6	6
5	2	2	4	6	7
5	2	2	4	6	8
5	2	2	4	6	9
5	2	2	4	6	10
5	2	2	4	6	11
5	2	3	4	6	12
5	2	3	4	6	13
5	2	3	4	6	14
5	2	3	4	6	15
5	2	3	4	6	16
5	2	3	4	6	17
5	2	2	4	6	18
5	2	2	4	6	19
5	2	3	4	6	20
5	2	3	4	6	21
5	2	3	4	6	22
5	2	3	4	6	23
5	2	3	5	0	0
5	2	3	5	0	1
5	2	3	5	0	2
5	2	3	5	0	3
5	2	3	5	0	4
5	2	3	5	0	5
5	2	3	5	0	6
5	2	3	5	0	7
5	2	3	5	0	8
5	2	3	5	0	9
5	2	3	5	0	10
5	2	3	5	0	11
5	2	3	5	0	12
5	2	3	5	0	13
5	2	3	5	0	14
5	2	3	5	0	15
5	2	3	5	0	16
5	2	3	5	0	17
5	2	2	5	0	18
5	2	2	5	0	19
5	2	3	5	0	20
5	2	3	5	0	21
5	2	3	5	0	22
5	2	3	5	0	23
5	2	3	5	1	0
5	2	3	5	1	1
5	2	3	5	1	2
5	2	3	5	1	3
5	2	3	5	1	4
5	2	3	5	1	5
5	2	2	5	1	6
5	2	1	5	1	7
5	2	1	5	1	8
5	2	2	5	1	9
5	2	2	5	1	10
5	2	2	5	1	11
5	2	2	5	1	12
5	2	2	5	1	13
5	2	2	5	1	14
5	2	2	5	1	15
5	2	2	5	1	16
5	2	2	5	1	17
5	2	1	5	1	18
5	2	1	5	1	19
5	2	1	5	1	20
5	2	2	5	1	21
5	2	3	5	1	22
5	2	3	5	1	23
5	2	3	5	2	0
5	2	3	5	2	1
5	2	3	5	2	2
5	2	3	5	2	3
5	2	3	5	2	4
5	2	3	5	2	5
5	2	2	5	2	6
5	2	1	5	2	7
5	2	1	5	2	8
5	2	2	5	2	9
5	2	2	5	2	10
5	2	2	5	2	11
5	2	2	5	2	12
5	2	2	5	2	13
5	2	2	5	2	14
5	2	2	5	2	15
5	2	2	5	2	16
5	2	2	5	2	17
5	2	1	5	2	18
5	2	1	5	2	19
5	2	1	5	2	20
5	2	2	5	2	21
5	2	3	5	2	22
5	2	3	5	2	23
5	2	3	5	3	0
5	2	3	5	3	1
5	2	3	5	3	2
5	2	3	5	3	3
5	2	3	5	3	4
5	2	3	5	3	5
5	2	2	5	3	6
5	2	1	5	3	7
5	2	1	5	3	8
5	2	2	5	3	9
5	2	2	5	3	10
5	2	2	5	3	11
5	2	2	5	3	12
5	2	2	5	3	13
5	2	2	5	3	14
5	2	2	5	3	15
5	2	2	5	3	16
5	2	2	5	3	17
5	2	1	5	3	18
5	2	1	5	3	19
5	2	1	5	3	20
5	2	2	5	3	21
5	2	3	5	3	22
5	2	3	5	3	23
5	2	3	5	4	0
5	2	3	5	4	1
5	2	3	5	4	2
5	2	3	5	4	3
5	2	3	5	4	4
5	2	3	5	4	5
5	2	2	5	4	6
5	2	1	5	4	7
5	2	1	5	4	8
5	2	2	5	4	9
5	2	2	5	4	10
5	2	2	5	4	11
5	2	2	5	4	12
5	2	2	5	4	13
5	2	2	5	4	14
5	2	2	5	4	15
5	2	2	5	4	16
5	2	2	5	4	17
5	2	1	5	4	18
5	2	1	5	4	19
5	2	1	5	4	20
5	2	2	5	4	21
5	2	3	5	4	22
5	2	3	5	4	23
5	2	3	5	5	0
5	2	3	5	5	1
5	2	3	5	5	2
5	2	3	5	5	3
5	2	3	5	5	4
5	2	3	5	5	5
5	2	2	5	5	6
5	2	1	5	5	7
5	2	1	5	5	8
5	2	2	5	5	9
5	2	2	5	5	10
5	2	2	5	5	11
5	2	2	5	5	12
5	2	2	5	5	13
5	2	2	5	5	14
5	2	2	5	5	15
5	2	2	5	5	16
5	2	2	5	5	17
5	2	1	5	5	18
5	2	1	5	5	19
5	2	1	5	5	20
5	2	2	5	5	21
5	2	3	5	5	22
5	2	3	5	5	23
5	2	3	5	6	0
5	2	3	5	6	1
5	2	3	5	6	2
5	2	3	5	6	3
5	2	3	5	6	4
5	2	3	5	6	5
5	2	3	5	6	6
5	2	2	5	6	7
5	2	2	5	6	8
5	2	2	5	6	9
5	2	2	5	6	10
5	2	2	5	6	11
5	2	3	5	6	12
5	2	3	5	6	13
5	2	3	5	6	14
5	2	3	5	6	15
5	2	3	5	6	16
5	2	3	5	6	17
5	2	2	5	6	18
5	2	2	5	6	19
5	2	3	5	6	20
5	2	3	5	6	21
5	2	3	5	6	22
5	2	3	5	6	23
5	1	3	6	0	0
5	1	3	6	0	1
5	1	3	6	0	2
5	1	3	6	0	3
5	1	3	6	0	4
5	1	3	6	0	5
5	1	3	6	0	6
5	1	3	6	0	7
5	1	3	6	0	8
5	1	3	6	0	9
5	1	3	6	0	10
5	1	3	6	0	11
5	1	3	6	0	12
5	1	3	6	0	13
5	1	3	6	0	14
5	1	3	6	0	15
5	1	3	6	0	16
5	1	2	6	0	17
5	1	2	6	0	18
5	1	3	6	0	19
5	1	3	6	0	20
5	1	3	6	0	21
5	1	3	6	0	22
5	1	3	6	0	23
5	1	3	6	1	0
5	1	3	6	1	1
5	1	3	6	1	2
5	1	3	6	1	3
5	1	3	6	1	4
5	1	3	6	1	5
5	1	1	6	1	6
5	1	1	6	1	7
5	1	2	6	1	8
5	1	2	6	1	9
5	1	2	6	1	10
5	1	2	6	1	11
5	1	2	6	1	12
5	1	2	6	1	13
5	1	2	6	1	14
5	1	2	6	1	15
5	1	2	6	1	16
5	1	1	6	1	17
5	1	1	6	1	18
5	1	1	6	1	19
5	1	2	6	1	20
5	1	2	6	1	21
5	1	3	6	1	22
5	1	3	6	1	23
5	1	3	6	2	0
5	1	3	6	2	1
5	1	3	6	2	2
5	1	3	6	2	3
5	1	3	6	2	4
5	1	3	6	2	5
5	1	1	6	2	6
5	1	1	6	2	7
5	1	2	6	2	8
5	1	2	6	2	9
5	1	2	6	2	10
5	1	2	6	2	11
5	1	2	6	2	12
5	1	2	6	2	13
5	1	2	6	2	14
5	1	2	6	2	15
5	1	2	6	2	16
5	1	1	6	2	17
5	1	1	6	2	18
5	1	1	6	2	19
5	1	2	6	2	20
5	1	2	6	2	21
5	1	3	6	2	22
5	1	3	6	2	23
5	1	3	6	3	0
5	1	3	6	3	1
5	1	3	6	3	2
5	1	3	6	3	3
5	1	3	6	3	4
5	1	3	6	3	5
5	1	1	6	3	6
5	1	1	6	3	7
5	1	2	6	3	8
5	1	2	6	3	9
5	1	2	6	3	10
5	1	2	6	3	11
5	1	2	6	3	12
5	1	2	6	3	13
5	1	2	6	3	14
5	1	2	6	3	15
5	1	2	6	3	16
5	1	1	6	3	17
5	1	1	6	3	18
5	1	1	6	3	19
5	1	2	6	3	20
5	1	2	6	3	21
5	1	3	6	3	22
5	1	3	6	3	23
5	1	3	6	4	0
5	1	3	6	4	1
5	1	3	6	4	2
5	1	3	6	4	3
5	1	3	6	4	4
5	1	3	6	4	5
5	1	1	6	4	6
5	1	1	6	4	7
5	1	2	6	4	8
5	1	2	6	4	9
5	1	2	6	4	10
5	1	2	6	4	11
5	1	2	6	4	12
5	1	2	6	4	13
5	1	2	6	4	14
5	1	2	6	4	15
5	1	2	6	4	16
5	1	1	6	4	17
5	1	1	6	4	18
5	1	1	6	4	19
5	1	2	6	4	20
5	1	2	6	4	21
5	1	3	6	4	22
5	1	3	6	4	23
5	1	3	6	5	0
5	1	3	6	5	1
5	1	3	6	5	2
5	1	3	6	5	3
5	1	3	6	5	4
5	1	3	6	5	5
5	1	1	6	5	6
5	1	1	6	5	7
5	1	2	6	5	8
5	1	2	6	5	9
5	1	2	6	5	10
5	1	2	6	5	11
5	1	2	6	5	12
5	1	2	6	5	13
5	1	2	6	5	14
5	1	2	6	5	15
5	1	2	6	5	16
5	1	1	6	5	17
5	1	1	6	5	18
5	1	1	6	5	19
5	1	2	6	5	20
5	1	2	6	5	21
5	1	3	6	5	22
5	1	3	6	5	23
5	1	3	6	6	0
5	1	3	6	6	1
5	1	3	6	6	2
5	1	3	6	6	3
5	1	3	6	6	4
5	1	3	6	6	5
5	1	3	6	6	6
5	1	2	6	6	7
5	1	2	6	6	8
5	1	2	6	6	9
5	1	2	6	6	10
5	1	2	6	6	11
5	1	3	6	6	12
5	1	3	6	6	13
5	1	3	6	6	14
5	1	3	6	6	15
5	1	3	6	6	16
5	1	2	6	6	17
5	1	2	6	6	18
5	1	3	6	6	19
5	1	3	6	6	20
5	1	3	6	6	21
5	1	3	6	6	22
5	1	3	6	6	23
5	1	3	7	0	0
5	1	3	7	0	1
5	1	3	7	0	2
5	1	3	7	0	3
5	1	3	7	0	4
5	1	3	7	0	5
5	1	3	7	0	6
5	1	3	7	0	7
5	1	3	7	0	8
5	1	3	7	0	9
5	1	3	7	0	10
5	1	3	7	0	11
5	1	3	7	0	12
5	1	3	7	0	13
5	1	3	7	0	14
5	1	3	7	0	15
5	1	3	7	0	16
5	1	2	7	0	17
5	1	2	7	0	18
5	1	3	7	0	19
5	1	3	7	0	20
5	1	3	7	0	21
5	1	3	7	0	22
5	1	3	7	0	23
5	1	3	7	1	0
5	1	3	7	1	1
5	1	3	7	1	2
5	1	3	7	1	3
5	1	3	7	1	4
5	1	3	7	1	5
5	1	1	7	1	6
5	1	1	7	1	7
5	1	2	7	1	8
5	1	2	7	1	9
5	1	2	7	1	10
5	1	2	7	1	11
5	1	2	7	1	12
5	1	2	7	1	13
5	1	2	7	1	14
5	1	2	7	1	15
5	1	2	7	1	16
5	1	1	7	1	17
5	1	1	7	1	18
5	1	1	7	1	19
5	1	2	7	1	20
5	1	2	7	1	21
5	1	3	7	1	22
5	1	3	7	1	23
5	1	3	7	2	0
5	1	3	7	2	1
5	1	3	7	2	2
5	1	3	7	2	3
5	1	3	7	2	4
5	1	3	7	2	5
5	1	1	7	2	6
5	1	1	7	2	7
5	1	2	7	2	8
5	1	2	7	2	9
5	1	2	7	2	10
5	1	2	7	2	11
5	1	2	7	2	12
5	1	2	7	2	13
5	1	2	7	2	14
5	1	2	7	2	15
5	1	2	7	2	16
5	1	1	7	2	17
5	1	1	7	2	18
5	1	1	7	2	19
5	1	2	7	2	20
5	1	2	7	2	21
5	1	3	7	2	22
5	1	3	7	2	23
5	1	3	7	3	0
5	1	3	7	3	1
5	1	3	7	3	2
5	1	3	7	3	3
5	1	3	7	3	4
5	1	3	7	3	5
5	1	1	7	3	6
5	1	1	7	3	7
5	1	2	7	3	8
5	1	2	7	3	9
5	1	2	7	3	10
5	1	2	7	3	11
5	1	2	7	3	12
5	1	2	7	3	13
5	1	2	7	3	14
5	1	2	7	3	15
5	1	2	7	3	16
5	1	1	7	3	17
5	1	1	7	3	18
5	1	1	7	3	19
5	1	2	7	3	20
5	1	2	7	3	21
5	1	3	7	3	22
5	1	3	7	3	23
5	1	3	7	4	0
5	1	3	7	4	1
5	1	3	7	4	2
5	1	3	7	4	3
5	1	3	7	4	4
5	1	3	7	4	5
5	1	1	7	4	6
5	1	1	7	4	7
5	1	2	7	4	8
5	1	2	7	4	9
5	1	2	7	4	10
5	1	2	7	4	11
5	1	2	7	4	12
5	1	2	7	4	13
5	1	2	7	4	14
5	1	2	7	4	15
5	1	2	7	4	16
5	1	1	7	4	17
5	1	1	7	4	18
5	1	1	7	4	19
5	1	2	7	4	20
5	1	2	7	4	21
5	1	3	7	4	22
5	1	3	7	4	23
5	1	3	7	5	0
5	1	3	7	5	1
5	1	3	7	5	2
5	1	3	7	5	3
5	1	3	7	5	4
5	1	3	7	5	5
5	1	1	7	5	6
5	1	1	7	5	7
5	1	2	7	5	8
5	1	2	7	5	9
5	1	2	7	5	10
5	1	2	7	5	11
5	1	2	7	5	12
5	1	2	7	5	13
5	1	2	7	5	14
5	1	2	7	5	15
5	1	2	7	5	16
5	1	1	7	5	17
5	1	1	7	5	18
5	1	1	7	5	19
5	1	2	7	5	20
5	1	2	7	5	21
5	1	3	7	5	22
5	1	3	7	5	23
5	1	3	7	6	0
5	1	3	7	6	1
5	1	3	7	6	2
5	1	3	7	6	3
5	1	3	7	6	4
5	1	3	7	6	5
5	1	3	7	6	6
5	1	2	7	6	7
5	1	2	7	6	8
5	1	2	7	6	9
5	1	2	7	6	10
5	1	2	7	6	11
5	1	3	7	6	12
5	1	3	7	6	13
5	1	3	7	6	14
5	1	3	7	6	15
5	1	3	7	6	16
5	1	2	7	6	17
5	1	2	7	6	18
5	1	3	7	6	19
5	1	3	7	6	20
5	1	3	7	6	21
5	1	3	7	6	22
5	1	3	7	6	23
5	1	3	8	0	0
5	1	3	8	0	1
5	1	3	8	0	2
5	1	3	8	0	3
5	1	3	8	0	4
5	1	3	8	0	5
5	1	3	8	0	6
5	1	3	8	0	7
5	1	3	8	0	8
5	1	3	8	0	9
5	1	3	8	0	10
5	1	3	8	0	11
5	1	3	8	0	12
5	1	3	8	0	13
5	1	3	8	0	14
5	1	3	8	0	15
5	1	3	8	0	16
5	1	2	8	0	17
5	1	2	8	0	18
5	1	3	8	0	19
5	1	3	8	0	20
5	1	3	8	0	21
5	1	3	8	0	22
5	1	3	8	0	23
5	1	3	8	1	0
5	1	3	8	1	1
5	1	3	8	1	2
5	1	3	8	1	3
5	1	3	8	1	4
5	1	3	8	1	5
5	1	1	8	1	6
5	1	1	8	1	7
5	1	2	8	1	8
5	1	2	8	1	9
5	1	2	8	1	10
5	1	2	8	1	11
5	1	2	8	1	12
5	1	2	8	1	13
5	1	2	8	1	14
5	1	2	8	1	15
5	1	2	8	1	16
5	1	1	8	1	17
5	1	1	8	1	18
5	1	1	8	1	19
5	1	2	8	1	20
5	1	2	8	1	21
5	1	3	8	1	22
5	1	3	8	1	23
5	1	3	8	2	0
5	1	3	8	2	1
5	1	3	8	2	2
5	1	3	8	2	3
5	1	3	8	2	4
5	1	3	8	2	5
5	1	1	8	2	6
5	1	1	8	2	7
5	1	2	8	2	8
5	1	2	8	2	9
5	1	2	8	2	10
5	1	2	8	2	11
5	1	2	8	2	12
5	1	2	8	2	13
5	1	2	8	2	14
5	1	2	8	2	15
5	1	2	8	2	16
5	1	1	8	2	17
5	1	1	8	2	18
5	1	1	8	2	19
5	1	2	8	2	20
5	1	2	8	2	21
5	1	3	8	2	22
5	1	3	8	2	23
5	1	3	8	3	0
5	1	3	8	3	1
5	1	3	8	3	2
5	1	3	8	3	3
5	1	3	8	3	4
5	1	3	8	3	5
5	1	1	8	3	6
5	1	1	8	3	7
5	1	2	8	3	8
5	1	2	8	3	9
5	1	2	8	3	10
5	1	2	8	3	11
5	1	2	8	3	12
5	1	2	8	3	13
5	1	2	8	3	14
5	1	2	8	3	15
5	1	2	8	3	16
5	1	1	8	3	17
5	1	1	8	3	18
5	1	1	8	3	19
5	1	2	8	3	20
5	1	2	8	3	21
5	1	3	8	3	22
5	1	3	8	3	23
5	1	3	8	4	0
5	1	3	8	4	1
5	1	3	8	4	2
5	1	3	8	4	3
5	1	3	8	4	4
5	1	3	8	4	5
5	1	1	8	4	6
5	1	1	8	4	7
5	1	2	8	4	8
5	1	2	8	4	9
5	1	2	8	4	10
5	1	2	8	4	11
5	1	2	8	4	12
5	1	2	8	4	13
5	1	2	8	4	14
5	1	2	8	4	15
5	1	2	8	4	16
5	1	1	8	4	17
5	1	1	8	4	18
5	1	1	8	4	19
5	1	2	8	4	20
5	1	2	8	4	21
5	1	3	8	4	22
5	1	3	8	4	23
5	1	3	8	5	0
5	1	3	8	5	1
5	1	3	8	5	2
5	1	3	8	5	3
5	1	3	8	5	4
5	1	3	8	5	5
5	1	1	8	5	6
5	1	1	8	5	7
5	1	2	8	5	8
5	1	2	8	5	9
5	1	2	8	5	10
5	1	2	8	5	11
5	1	2	8	5	12
5	1	2	8	5	13
5	1	2	8	5	14
5	1	2	8	5	15
5	1	2	8	5	16
5	1	1	8	5	17
5	1	1	8	5	18
5	1	1	8	5	19
5	1	2	8	5	20
5	1	2	8	5	21
5	1	3	8	5	22
5	1	3	8	5	23
5	1	3	8	6	0
5	1	3	8	6	1
5	1	3	8	6	2
5	1	3	8	6	3
5	1	3	8	6	4
5	1	3	8	6	5
5	1	3	8	6	6
5	1	2	8	6	7
5	1	2	8	6	8
5	1	2	8	6	9
5	1	2	8	6	10
5	1	2	8	6	11
5	1	3	8	6	12
5	1	3	8	6	13
5	1	3	8	6	14
5	1	3	8	6	15
5	1	3	8	6	16
5	1	2	8	6	17
5	1	2	8	6	18
5	1	3	8	6	19
5	1	3	8	6	20
5	1	3	8	6	21
5	1	3	8	6	22
5	1	3	8	6	23
5	2	3	9	0	0
5	2	3	9	0	1
5	2	3	9	0	2
5	2	3	9	0	3
5	2	3	9	0	4
5	2	3	9	0	5
5	2	3	9	0	6
5	2	3	9	0	7
5	2	3	9	0	8
5	2	3	9	0	9
5	2	3	9	0	10
5	2	3	9	0	11
5	2	3	9	0	12
5	2	3	9	0	13
5	2	3	9	0	14
5	2	3	9	0	15
5	2	3	9	0	16
5	2	3	9	0	17
5	2	2	9	0	18
5	2	2	9	0	19
5	2	3	9	0	20
5	2	3	9	0	21
5	2	3	9	0	22
5	2	3	9	0	23
5	2	3	9	1	0
5	2	3	9	1	1
5	2	3	9	1	2
5	2	3	9	1	3
5	2	3	9	1	4
5	2	3	9	1	5
5	2	2	9	1	6
5	2	1	9	1	7
5	2	1	9	1	8
5	2	2	9	1	9
5	2	2	9	1	10
5	2	2	9	1	11
5	2	2	9	1	12
5	2	2	9	1	13
5	2	2	9	1	14
5	2	2	9	1	15
5	2	2	9	1	16
5	2	2	9	1	17
5	2	1	9	1	18
5	2	1	9	1	19
5	2	1	9	1	20
5	2	2	9	1	21
5	2	3	9	1	22
5	2	3	9	1	23
5	2	3	9	2	0
5	2	3	9	2	1
5	2	3	9	2	2
5	2	3	9	2	3
5	2	3	9	2	4
5	2	3	9	2	5
5	2	2	9	2	6
5	2	1	9	2	7
5	2	1	9	2	8
5	2	2	9	2	9
5	2	2	9	2	10
5	2	2	9	2	11
5	2	2	9	2	12
5	2	2	9	2	13
5	2	2	9	2	14
5	2	2	9	2	15
5	2	2	9	2	16
5	2	2	9	2	17
5	2	1	9	2	18
5	2	1	9	2	19
5	2	1	9	2	20
5	2	2	9	2	21
5	2	3	9	2	22
5	2	3	9	2	23
5	2	3	9	3	0
5	2	3	9	3	1
5	2	3	9	3	2
5	2	3	9	3	3
5	2	3	9	3	4
5	2	3	9	3	5
5	2	2	9	3	6
5	2	1	9	3	7
5	2	1	9	3	8
5	2	2	9	3	9
5	2	2	9	3	10
5	2	2	9	3	11
5	2	2	9	3	12
5	2	2	9	3	13
5	2	2	9	3	14
5	2	2	9	3	15
5	2	2	9	3	16
5	2	2	9	3	17
5	2	1	9	3	18
5	2	1	9	3	19
5	2	1	9	3	20
5	2	2	9	3	21
5	2	3	9	3	22
5	2	3	9	3	23
5	2	3	9	4	0
5	2	3	9	4	1
5	2	3	9	4	2
5	2	3	9	4	3
5	2	3	9	4	4
5	2	3	9	4	5
5	2	2	9	4	6
5	2	1	9	4	7
5	2	1	9	4	8
5	2	2	9	4	9
5	2	2	9	4	10
5	2	2	9	4	11
5	2	2	9	4	12
5	2	2	9	4	13
5	2	2	9	4	14
5	2	2	9	4	15
5	2	2	9	4	16
5	2	2	9	4	17
5	2	1	9	4	18
5	2	1	9	4	19
5	2	1	9	4	20
5	2	2	9	4	21
5	2	3	9	4	22
5	2	3	9	4	23
5	2	3	9	5	0
5	2	3	9	5	1
5	2	3	9	5	2
5	2	3	9	5	3
5	2	3	9	5	4
5	2	3	9	5	5
5	2	2	9	5	6
5	2	1	9	5	7
5	2	1	9	5	8
5	2	2	9	5	9
5	2	2	9	5	10
5	2	2	9	5	11
5	2	2	9	5	12
5	2	2	9	5	13
5	2	2	9	5	14
5	2	2	9	5	15
5	2	2	9	5	16
5	2	2	9	5	17
5	2	1	9	5	18
5	2	1	9	5	19
5	2	1	9	5	20
5	2	2	9	5	21
5	2	3	9	5	22
5	2	3	9	5	23
5	2	3	9	6	0
5	2	3	9	6	1
5	2	3	9	6	2
5	2	3	9	6	3
5	2	3	9	6	4
5	2	3	9	6	5
5	2	3	9	6	6
5	2	2	9	6	7
5	2	2	9	6	8
5	2	2	9	6	9
5	2	2	9	6	10
5	2	2	9	6	11
5	2	3	9	6	12
5	2	3	9	6	13
5	2	3	9	6	14
5	2	3	9	6	15
5	2	3	9	6	16
5	2	3	9	6	17
5	2	2	9	6	18
5	2	2	9	6	19
5	2	3	9	6	20
5	2	3	9	6	21
5	2	3	9	6	22
5	2	3	9	6	23
5	2	3	10	0	0
5	2	3	10	0	1
5	2	3	10	0	2
5	2	3	10	0	3
5	2	3	10	0	4
5	2	3	10	0	5
5	2	3	10	0	6
5	2	3	10	0	7
5	2	3	10	0	8
5	2	3	10	0	9
5	2	3	10	0	10
5	2	3	10	0	11
5	2	3	10	0	12
5	2	3	10	0	13
5	2	3	10	0	14
5	2	3	10	0	15
5	2	3	10	0	16
5	2	3	10	0	17
5	2	2	10	0	18
5	2	2	10	0	19
5	2	3	10	0	20
5	2	3	10	0	21
5	2	3	10	0	22
5	2	3	10	0	23
5	2	3	10	1	0
5	2	3	10	1	1
5	2	3	10	1	2
5	2	3	10	1	3
5	2	3	10	1	4
5	2	3	10	1	5
5	2	2	10	1	6
5	2	1	10	1	7
5	2	1	10	1	8
5	2	2	10	1	9
5	2	2	10	1	10
5	2	2	10	1	11
5	2	2	10	1	12
5	2	2	10	1	13
5	2	2	10	1	14
5	2	2	10	1	15
5	2	2	10	1	16
5	2	2	10	1	17
5	2	1	10	1	18
5	2	1	10	1	19
5	2	1	10	1	20
5	2	2	10	1	21
5	2	3	10	1	22
5	2	3	10	1	23
5	2	3	10	2	0
5	2	3	10	2	1
5	2	3	10	2	2
5	2	3	10	2	3
5	2	3	10	2	4
5	2	3	10	2	5
5	2	2	10	2	6
5	2	1	10	2	7
5	2	1	10	2	8
5	2	2	10	2	9
5	2	2	10	2	10
5	2	2	10	2	11
5	2	2	10	2	12
5	2	2	10	2	13
5	2	2	10	2	14
5	2	2	10	2	15
5	2	2	10	2	16
5	2	2	10	2	17
5	2	1	10	2	18
5	2	1	10	2	19
5	2	1	10	2	20
5	2	2	10	2	21
5	2	3	10	2	22
5	2	3	10	2	23
5	2	3	10	3	0
5	2	3	10	3	1
5	2	3	10	3	2
5	2	3	10	3	3
5	2	3	10	3	4
5	2	3	10	3	5
5	2	2	10	3	6
5	2	1	10	3	7
5	2	1	10	3	8
5	2	2	10	3	9
5	2	2	10	3	10
5	2	2	10	3	11
5	2	2	10	3	12
5	2	2	10	3	13
5	2	2	10	3	14
5	2	2	10	3	15
5	2	2	10	3	16
5	2	2	10	3	17
5	2	1	10	3	18
5	2	1	10	3	19
5	2	1	10	3	20
5	2	2	10	3	21
5	2	3	10	3	22
5	2	3	10	3	23
5	2	3	10	4	0
5	2	3	10	4	1
5	2	3	10	4	2
5	2	3	10	4	3
5	2	3	10	4	4
5	2	3	10	4	5
5	2	2	10	4	6
5	2	1	10	4	7
5	2	1	10	4	8
5	2	2	10	4	9
5	2	2	10	4	10
5	2	2	10	4	11
5	2	2	10	4	12
5	2	2	10	4	13
5	2	2	10	4	14
5	2	2	10	4	15
5	2	2	10	4	16
5	2	2	10	4	17
5	2	1	10	4	18
5	2	1	10	4	19
5	2	1	10	4	20
5	2	2	10	4	21
5	2	3	10	4	22
5	2	3	10	4	23
5	2	3	10	5	0
5	2	3	10	5	1
5	2	3	10	5	2
5	2	3	10	5	3
5	2	3	10	5	4
5	2	3	10	5	5
5	2	2	10	5	6
5	2	1	10	5	7
5	2	1	10	5	8
5	2	2	10	5	9
5	2	2	10	5	10
5	2	2	10	5	11
5	2	2	10	5	12
5	2	2	10	5	13
5	2	2	10	5	14
5	2	2	10	5	15
5	2	2	10	5	16
5	2	2	10	5	17
5	2	1	10	5	18
5	2	1	10	5	19
5	2	1	10	5	20
5	2	2	10	5	21
5	2	3	10	5	22
5	2	3	10	5	23
5	2	3	10	6	0
5	2	3	10	6	1
5	2	3	10	6	2
5	2	3	10	6	3
5	2	3	10	6	4
5	2	3	10	6	5
5	2	3	10	6	6
5	2	2	10	6	7
5	2	2	10	6	8
5	2	2	10	6	9
5	2	2	10	6	10
5	2	2	10	6	11
5	2	3	10	6	12
5	2	3	10	6	13
5	2	3	10	6	14
5	2	3	10	6	15
5	2	3	10	6	16
5	2	3	10	6	17
5	2	2	10	6	18
5	2	2	10	6	19
5	2	3	10	6	20
5	2	3	10	6	21
5	2	3	10	6	22
5	2	3	10	6	23
5	2	3	11	0	0
5	2	3	11	0	1
5	2	3	11	0	2
5	2	3	11	0	3
5	2	3	11	0	4
5	2	3	11	0	5
5	2	3	11	0	6
5	2	3	11	0	7
5	2	3	11	0	8
5	2	3	11	0	9
5	2	3	11	0	10
5	2	3	11	0	11
5	2	3	11	0	12
5	2	3	11	0	13
5	2	3	11	0	14
5	2	3	11	0	15
5	2	3	11	0	16
5	2	3	11	0	17
5	2	2	11	0	18
5	2	2	11	0	19
5	2	3	11	0	20
5	2	3	11	0	21
5	2	3	11	0	22
5	2	3	11	0	23
5	2	3	11	1	0
5	2	3	11	1	1
5	2	3	11	1	2
5	2	3	11	1	3
5	2	3	11	1	4
5	2	3	11	1	5
5	2	2	11	1	6
5	2	1	11	1	7
5	2	1	11	1	8
5	2	2	11	1	9
5	2	2	11	1	10
5	2	2	11	1	11
5	2	2	11	1	12
5	2	2	11	1	13
5	2	2	11	1	14
5	2	2	11	1	15
5	2	2	11	1	16
5	2	2	11	1	17
5	2	1	11	1	18
5	2	1	11	1	19
5	2	1	11	1	20
5	2	2	11	1	21
5	2	3	11	1	22
5	2	3	11	1	23
5	2	3	11	2	0
5	2	3	11	2	1
5	2	3	11	2	2
5	2	3	11	2	3
5	2	3	11	2	4
5	2	3	11	2	5
5	2	2	11	2	6
5	2	1	11	2	7
5	2	1	11	2	8
5	2	2	11	2	9
5	2	2	11	2	10
5	2	2	11	2	11
5	2	2	11	2	12
5	2	2	11	2	13
5	2	2	11	2	14
5	2	2	11	2	15
5	2	2	11	2	16
5	2	2	11	2	17
5	2	1	11	2	18
5	2	1	11	2	19
5	2	1	11	2	20
5	2	2	11	2	21
5	2	3	11	2	22
5	2	3	11	2	23
5	2	3	11	3	0
5	2	3	11	3	1
5	2	3	11	3	2
5	2	3	11	3	3
5	2	3	11	3	4
5	2	3	11	3	5
5	2	2	11	3	6
5	2	1	11	3	7
5	2	1	11	3	8
5	2	2	11	3	9
5	2	2	11	3	10
5	2	2	11	3	11
5	2	2	11	3	12
5	2	2	11	3	13
5	2	2	11	3	14
5	2	2	11	3	15
5	2	2	11	3	16
5	2	2	11	3	17
5	2	1	11	3	18
5	2	1	11	3	19
5	2	1	11	3	20
5	2	2	11	3	21
5	2	3	11	3	22
5	2	3	11	3	23
5	2	3	11	4	0
5	2	3	11	4	1
5	2	3	11	4	2
5	2	3	11	4	3
5	2	3	11	4	4
5	2	3	11	4	5
5	2	2	11	4	6
5	2	1	11	4	7
5	2	1	11	4	8
5	2	2	11	4	9
5	2	2	11	4	10
5	2	2	11	4	11
5	2	2	11	4	12
5	2	2	11	4	13
5	2	2	11	4	14
5	2	2	11	4	15
5	2	2	11	4	16
5	2	2	11	4	17
5	2	1	11	4	18
5	2	1	11	4	19
5	2	1	11	4	20
5	2	2	11	4	21
5	2	3	11	4	22
5	2	3	11	4	23
5	2	3	11	5	0
5	2	3	11	5	1
5	2	3	11	5	2
5	2	3	11	5	3
5	2	3	11	5	4
5	2	3	11	5	5
5	2	2	11	5	6
5	2	1	11	5	7
5	2	1	11	5	8
5	2	2	11	5	9
5	2	2	11	5	10
5	2	2	11	5	11
5	2	2	11	5	12
5	2	2	11	5	13
5	2	2	11	5	14
5	2	2	11	5	15
5	2	2	11	5	16
5	2	2	11	5	17
5	2	1	11	5	18
5	2	1	11	5	19
5	2	1	11	5	20
5	2	2	11	5	21
5	2	3	11	5	22
5	2	3	11	5	23
5	2	3	11	6	0
5	2	3	11	6	1
5	2	3	11	6	2
5	2	3	11	6	3
5	2	3	11	6	4
5	2	3	11	6	5
5	2	3	11	6	6
5	2	2	11	6	7
5	2	2	11	6	8
5	2	2	11	6	9
5	2	2	11	6	10
5	2	2	11	6	11
5	2	3	11	6	12
5	2	3	11	6	13
5	2	3	11	6	14
5	2	3	11	6	15
5	2	3	11	6	16
5	2	3	11	6	17
5	2	2	11	6	18
5	2	2	11	6	19
5	2	3	11	6	20
5	2	3	11	6	21
5	2	3	11	6	22
5	2	3	11	6	23
5	2	3	12	0	0
5	2	3	12	0	1
5	2	3	12	0	2
5	2	3	12	0	3
5	2	3	12	0	4
5	2	3	12	0	5
5	2	3	12	0	6
5	2	3	12	0	7
5	2	3	12	0	8
5	2	3	12	0	9
5	2	3	12	0	10
5	2	3	12	0	11
5	2	3	12	0	12
5	2	3	12	0	13
5	2	3	12	0	14
5	2	3	12	0	15
5	2	3	12	0	16
5	2	3	12	0	17
5	2	2	12	0	18
5	2	2	12	0	19
5	2	3	12	0	20
5	2	3	12	0	21
5	2	3	12	0	22
5	2	3	12	0	23
5	2	3	12	1	0
5	2	3	12	1	1
5	2	3	12	1	2
5	2	3	12	1	3
5	2	3	12	1	4
5	2	3	12	1	5
5	2	2	12	1	6
5	2	1	12	1	7
5	2	1	12	1	8
5	2	2	12	1	9
5	2	2	12	1	10
5	2	2	12	1	11
5	2	2	12	1	12
5	2	2	12	1	13
5	2	2	12	1	14
5	2	2	12	1	15
5	2	2	12	1	16
5	2	2	12	1	17
5	2	1	12	1	18
5	2	1	12	1	19
5	2	1	12	1	20
5	2	2	12	1	21
5	2	3	12	1	22
5	2	3	12	1	23
5	2	3	12	2	0
5	2	3	12	2	1
5	2	3	12	2	2
5	2	3	12	2	3
5	2	3	12	2	4
5	2	3	12	2	5
5	2	2	12	2	6
5	2	1	12	2	7
5	2	1	12	2	8
5	2	2	12	2	9
5	2	2	12	2	10
5	2	2	12	2	11
5	2	2	12	2	12
5	2	2	12	2	13
5	2	2	12	2	14
5	2	2	12	2	15
5	2	2	12	2	16
5	2	2	12	2	17
5	2	1	12	2	18
5	2	1	12	2	19
5	2	1	12	2	20
5	2	2	12	2	21
5	2	3	12	2	22
5	2	3	12	2	23
5	2	3	12	3	0
5	2	3	12	3	1
5	2	3	12	3	2
5	2	3	12	3	3
5	2	3	12	3	4
5	2	3	12	3	5
5	2	2	12	3	6
5	2	1	12	3	7
5	2	1	12	3	8
5	2	2	12	3	9
5	2	2	12	3	10
5	2	2	12	3	11
5	2	2	12	3	12
5	2	2	12	3	13
5	2	2	12	3	14
5	2	2	12	3	15
5	2	2	12	3	16
5	2	2	12	3	17
5	2	1	12	3	18
5	2	1	12	3	19
5	2	1	12	3	20
5	2	2	12	3	21
5	2	3	12	3	22
5	2	3	12	3	23
5	2	3	12	4	0
5	2	3	12	4	1
5	2	3	12	4	2
5	2	3	12	4	3
5	2	3	12	4	4
5	2	3	12	4	5
5	2	2	12	4	6
5	2	1	12	4	7
5	2	1	12	4	8
5	2	2	12	4	9
5	2	2	12	4	10
5	2	2	12	4	11
5	2	2	12	4	12
5	2	2	12	4	13
5	2	2	12	4	14
5	2	2	12	4	15
5	2	2	12	4	16
5	2	2	12	4	17
5	2	1	12	4	18
5	2	1	12	4	19
5	2	1	12	4	20
5	2	2	12	4	21
5	2	3	12	4	22
5	2	3	12	4	23
5	2	3	12	5	0
5	2	3	12	5	1
5	2	3	12	5	2
5	2	3	12	5	3
5	2	3	12	5	4
5	2	3	12	5	5
5	2	2	12	5	6
5	2	1	12	5	7
5	2	1	12	5	8
5	2	2	12	5	9
5	2	2	12	5	10
5	2	2	12	5	11
5	2	2	12	5	12
5	2	2	12	5	13
5	2	2	12	5	14
5	2	2	12	5	15
5	2	2	12	5	16
5	2	2	12	5	17
5	2	1	12	5	18
5	2	1	12	5	19
5	2	1	12	5	20
5	2	2	12	5	21
5	2	3	12	5	22
5	2	3	12	5	23
5	2	3	12	6	0
5	2	3	12	6	1
5	2	3	12	6	2
5	2	3	12	6	3
5	2	3	12	6	4
5	2	3	12	6	5
5	2	3	12	6	6
5	2	2	12	6	7
5	2	2	12	6	8
5	2	2	12	6	9
5	2	2	12	6	10
5	2	2	12	6	11
5	2	3	12	6	12
5	2	3	12	6	13
5	2	3	12	6	14
5	2	3	12	6	15
5	2	3	12	6	16
5	2	3	12	6	17
5	2	2	12	6	18
5	2	2	12	6	19
5	2	3	12	6	20
5	2	3	12	6	21
5	2	3	12	6	22
5	2	3	12	6	23
7	3	4	1	0	0
7	3	4	2	0	0
7	3	4	3	0	0
7	3	4	4	0	0
7	3	4	5	0	0
7	3	4	6	0	0
7	3	4	7	0	0
7	3	4	8	0	0
7	3	4	9	0	0
7	3	4	10	0	0
7	3	4	11	0	0
7	3	4	12	0	0
7	3	4	1	1	0
7	3	4	2	1	0
7	3	4	3	1	0
7	3	4	4	1	0
7	3	4	5	1	0
7	3	4	6	1	0
7	3	4	7	1	0
7	3	4	8	1	0
7	3	4	9	1	0
7	3	4	10	1	0
7	3	4	11	1	0
7	3	4	12	1	0
7	3	4	1	2	0
7	3	4	2	2	0
7	3	4	3	2	0
7	3	4	4	2	0
7	3	4	5	2	0
7	3	4	6	2	0
7	3	4	7	2	0
7	3	4	8	2	0
7	3	4	9	2	0
7	3	4	10	2	0
7	3	4	11	2	0
7	3	4	12	2	0
7	3	4	1	3	0
7	3	4	2	3	0
7	3	4	3	3	0
7	3	4	4	3	0
7	3	4	5	3	0
7	3	4	6	3	0
7	3	4	7	3	0
7	3	4	8	3	0
7	3	4	9	3	0
7	3	4	10	3	0
7	3	4	11	3	0
7	3	4	12	3	0
7	3	4	1	4	0
7	3	4	2	4	0
7	3	4	3	4	0
7	3	4	4	4	0
7	3	4	5	4	0
7	3	4	6	4	0
7	3	4	7	4	0
7	3	4	8	4	0
7	3	4	9	4	0
7	3	4	10	4	0
7	3	4	11	4	0
7	3	4	12	4	0
7	3	4	1	5	0
7	3	4	2	5	0
7	3	4	3	5	0
7	3	4	4	5	0
7	3	4	5	5	0
7	3	4	6	5	0
7	3	4	7	5	0
7	3	4	8	5	0
7	3	4	9	5	0
7	3	4	10	5	0
7	3	4	11	5	0
7	3	4	12	5	0
7	3	4	1	6	0
7	3	4	2	6	0
7	3	4	3	6	0
7	3	4	4	6	0
7	3	4	5	6	0
7	3	4	6	6	0
7	3	4	7	6	0
7	3	4	8	6	0
7	3	4	9	6	0
7	3	4	10	6	0
7	3	4	11	6	0
7	3	4	12	6	0
7	3	4	1	0	1
7	3	4	2	0	1
7	3	4	3	0	1
7	3	4	4	0	1
7	3	4	5	0	1
7	3	4	6	0	1
7	3	4	7	0	1
7	3	4	8	0	1
7	3	4	9	0	1
7	3	4	10	0	1
7	3	4	11	0	1
7	3	4	12	0	1
7	3	4	1	1	1
7	3	4	2	1	1
7	3	4	3	1	1
7	3	4	4	1	1
7	3	4	5	1	1
7	3	4	6	1	1
7	3	4	7	1	1
7	3	4	8	1	1
7	3	4	9	1	1
7	3	4	10	1	1
7	3	4	11	1	1
7	3	4	12	1	1
7	3	4	1	2	1
7	3	4	2	2	1
7	3	4	3	2	1
7	3	4	4	2	1
7	3	4	5	2	1
7	3	4	6	2	1
7	3	4	7	2	1
7	3	4	8	2	1
7	3	4	9	2	1
7	3	4	10	2	1
7	3	4	11	2	1
7	3	4	12	2	1
7	3	4	1	3	1
7	3	4	2	3	1
7	3	4	3	3	1
7	3	4	4	3	1
7	3	4	5	3	1
7	3	4	6	3	1
7	3	4	7	3	1
7	3	4	8	3	1
7	3	4	9	3	1
7	3	4	10	3	1
7	3	4	11	3	1
7	3	4	12	3	1
7	3	4	1	4	1
7	3	4	2	4	1
7	3	4	3	4	1
7	3	4	4	4	1
7	3	4	5	4	1
7	3	4	6	4	1
7	3	4	7	4	1
7	3	4	8	4	1
7	3	4	9	4	1
7	3	4	10	4	1
7	3	4	11	4	1
7	3	4	12	4	1
7	3	4	1	5	1
7	3	4	2	5	1
7	3	4	3	5	1
7	3	4	4	5	1
7	3	4	5	5	1
7	3	4	6	5	1
7	3	4	7	5	1
7	3	4	8	5	1
7	3	4	9	5	1
7	3	4	10	5	1
7	3	4	11	5	1
7	3	4	12	5	1
7	3	4	1	6	1
7	3	4	2	6	1
7	3	4	3	6	1
7	3	4	4	6	1
7	3	4	5	6	1
7	3	4	6	6	1
7	3	4	7	6	1
7	3	4	8	6	1
7	3	4	9	6	1
7	3	4	10	6	1
7	3	4	11	6	1
7	3	4	12	6	1
7	3	4	1	0	2
7	3	4	2	0	2
7	3	4	3	0	2
7	3	4	4	0	2
7	3	4	5	0	2
7	3	4	6	0	2
7	3	4	7	0	2
7	3	4	8	0	2
7	3	4	9	0	2
7	3	4	10	0	2
7	3	4	11	0	2
7	3	4	12	0	2
7	3	4	1	1	2
7	3	4	2	1	2
7	3	4	3	1	2
7	3	4	4	1	2
7	3	4	5	1	2
7	3	4	6	1	2
7	3	4	7	1	2
7	3	4	8	1	2
7	3	4	9	1	2
7	3	4	10	1	2
7	3	4	11	1	2
7	3	4	12	1	2
7	3	4	1	2	2
7	3	4	2	2	2
7	3	4	3	2	2
7	3	4	4	2	2
7	3	4	5	2	2
7	3	4	6	2	2
7	3	4	7	2	2
7	3	4	8	2	2
7	3	4	9	2	2
7	3	4	10	2	2
7	3	4	11	2	2
7	3	4	12	2	2
7	3	4	1	3	2
7	3	4	2	3	2
7	3	4	3	3	2
7	3	4	4	3	2
7	3	4	5	3	2
7	3	4	6	3	2
7	3	4	7	3	2
7	3	4	8	3	2
7	3	4	9	3	2
7	3	4	10	3	2
7	3	4	11	3	2
7	3	4	12	3	2
7	3	4	1	4	2
7	3	4	2	4	2
7	3	4	3	4	2
7	3	4	4	4	2
7	3	4	5	4	2
7	3	4	6	4	2
7	3	4	7	4	2
7	3	4	8	4	2
7	3	4	9	4	2
7	3	4	10	4	2
7	3	4	11	4	2
7	3	4	12	4	2
7	3	4	1	5	2
7	3	4	2	5	2
7	3	4	3	5	2
7	3	4	4	5	2
7	3	4	5	5	2
7	3	4	6	5	2
7	3	4	7	5	2
7	3	4	8	5	2
7	3	4	9	5	2
7	3	4	10	5	2
7	3	4	11	5	2
7	3	4	12	5	2
7	3	4	1	6	2
7	3	4	2	6	2
7	3	4	3	6	2
7	3	4	4	6	2
7	3	4	5	6	2
7	3	4	6	6	2
7	3	4	7	6	2
7	3	4	8	6	2
7	3	4	9	6	2
7	3	4	10	6	2
7	3	4	11	6	2
7	3	4	12	6	2
7	3	4	1	0	3
7	3	4	2	0	3
7	3	4	3	0	3
7	3	4	4	0	3
7	3	4	5	0	3
7	3	4	6	0	3
7	3	4	7	0	3
7	3	4	8	0	3
7	3	4	9	0	3
7	3	4	10	0	3
7	3	4	11	0	3
7	3	4	12	0	3
7	3	4	1	1	3
7	3	4	2	1	3
7	3	4	3	1	3
7	3	4	4	1	3
7	3	4	5	1	3
7	3	4	6	1	3
7	3	4	7	1	3
7	3	4	8	1	3
7	3	4	9	1	3
7	3	4	10	1	3
7	3	4	11	1	3
7	3	4	12	1	3
7	3	4	1	2	3
7	3	4	2	2	3
7	3	4	3	2	3
7	3	4	4	2	3
7	3	4	5	2	3
7	3	4	6	2	3
7	3	4	7	2	3
7	3	4	8	2	3
7	3	4	9	2	3
7	3	4	10	2	3
7	3	4	11	2	3
7	3	4	12	2	3
7	3	4	1	3	3
7	3	4	2	3	3
7	3	4	3	3	3
7	3	4	4	3	3
7	3	4	5	3	3
7	3	4	6	3	3
7	3	4	7	3	3
7	3	4	8	3	3
7	3	4	9	3	3
7	3	4	10	3	3
7	3	4	11	3	3
7	3	4	12	3	3
7	3	4	1	4	3
7	3	4	2	4	3
7	3	4	3	4	3
7	3	4	4	4	3
7	3	4	5	4	3
7	3	4	6	4	3
7	3	4	7	4	3
7	3	4	8	4	3
7	3	4	9	4	3
7	3	4	10	4	3
7	3	4	11	4	3
7	3	4	12	4	3
7	3	4	1	5	3
7	3	4	2	5	3
7	3	4	3	5	3
7	3	4	4	5	3
7	3	4	5	5	3
7	3	4	6	5	3
7	3	4	7	5	3
7	3	4	8	5	3
7	3	4	9	5	3
7	3	4	10	5	3
7	3	4	11	5	3
7	3	4	12	5	3
7	3	4	1	6	3
7	3	4	2	6	3
7	3	4	3	6	3
7	3	4	4	6	3
7	3	4	5	6	3
7	3	4	6	6	3
7	3	4	7	6	3
7	3	4	8	6	3
7	3	4	9	6	3
7	3	4	10	6	3
7	3	4	11	6	3
7	3	4	12	6	3
7	3	4	1	0	4
7	3	4	2	0	4
7	3	4	3	0	4
7	3	4	4	0	4
7	3	4	5	0	4
7	3	4	6	0	4
7	3	4	7	0	4
7	3	4	8	0	4
7	3	4	9	0	4
7	3	4	10	0	4
7	3	4	11	0	4
7	3	4	12	0	4
7	3	4	1	1	4
7	3	4	2	1	4
7	3	4	3	1	4
7	3	4	4	1	4
7	3	4	5	1	4
7	3	4	6	1	4
7	3	4	7	1	4
7	3	4	8	1	4
7	3	4	9	1	4
7	3	4	10	1	4
7	3	4	11	1	4
7	3	4	12	1	4
7	3	4	1	2	4
7	3	4	2	2	4
7	3	4	3	2	4
7	3	4	4	2	4
7	3	4	5	2	4
7	3	4	6	2	4
7	3	4	7	2	4
7	3	4	8	2	4
7	3	4	9	2	4
7	3	4	10	2	4
7	3	4	11	2	4
7	3	4	12	2	4
7	3	4	1	3	4
7	3	4	2	3	4
7	3	4	3	3	4
7	3	4	4	3	4
7	3	4	5	3	4
7	3	4	6	3	4
7	3	4	7	3	4
7	3	4	8	3	4
7	3	4	9	3	4
7	3	4	10	3	4
7	3	4	11	3	4
7	3	4	12	3	4
7	3	4	1	4	4
7	3	4	2	4	4
7	3	4	3	4	4
7	3	4	4	4	4
7	3	4	5	4	4
7	3	4	6	4	4
7	3	4	7	4	4
7	3	4	8	4	4
7	3	4	9	4	4
7	3	4	10	4	4
7	3	4	11	4	4
7	3	4	12	4	4
7	3	4	1	5	4
7	3	4	2	5	4
7	3	4	3	5	4
7	3	4	4	5	4
7	3	4	5	5	4
7	3	4	6	5	4
7	3	4	7	5	4
7	3	4	8	5	4
7	3	4	9	5	4
7	3	4	10	5	4
7	3	4	11	5	4
7	3	4	12	5	4
7	3	4	1	6	4
7	3	4	2	6	4
7	3	4	3	6	4
7	3	4	4	6	4
7	3	4	5	6	4
7	3	4	6	6	4
7	3	4	7	6	4
7	3	4	8	6	4
7	3	4	9	6	4
7	3	4	10	6	4
7	3	4	11	6	4
7	3	4	12	6	4
7	3	4	1	0	5
7	3	4	2	0	5
7	3	4	3	0	5
7	3	4	4	0	5
7	3	4	5	0	5
7	3	4	6	0	5
7	3	4	7	0	5
7	3	4	8	0	5
7	3	4	9	0	5
7	3	4	10	0	5
7	3	4	11	0	5
7	3	4	12	0	5
7	3	4	1	1	5
7	3	4	2	1	5
7	3	4	3	1	5
7	3	4	4	1	5
7	3	4	5	1	5
7	3	4	6	1	5
7	3	4	7	1	5
7	3	4	8	1	5
7	3	4	9	1	5
7	3	4	10	1	5
7	3	4	11	1	5
7	3	4	12	1	5
7	3	4	1	2	5
7	3	4	2	2	5
7	3	4	3	2	5
7	3	4	4	2	5
7	3	4	5	2	5
7	3	4	6	2	5
7	3	4	7	2	5
7	3	4	8	2	5
7	3	4	9	2	5
7	3	4	10	2	5
7	3	4	11	2	5
7	3	4	12	2	5
7	3	4	1	3	5
7	3	4	2	3	5
7	3	4	3	3	5
7	3	4	4	3	5
7	3	4	5	3	5
7	3	4	6	3	5
7	3	4	7	3	5
7	3	4	8	3	5
7	3	4	9	3	5
7	3	4	10	3	5
7	3	4	11	3	5
7	3	4	12	3	5
7	3	4	1	4	5
7	3	4	2	4	5
7	3	4	3	4	5
7	3	4	4	4	5
7	3	4	5	4	5
7	3	4	6	4	5
7	3	4	7	4	5
7	3	4	8	4	5
7	3	4	9	4	5
7	3	4	10	4	5
7	3	4	11	4	5
7	3	4	12	4	5
7	3	4	1	5	5
7	3	4	2	5	5
7	3	4	3	5	5
7	3	4	4	5	5
7	3	4	5	5	5
7	3	4	6	5	5
7	3	4	7	5	5
7	3	4	8	5	5
7	3	4	9	5	5
7	3	4	10	5	5
7	3	4	11	5	5
7	3	4	12	5	5
7	3	4	1	6	5
7	3	4	2	6	5
7	3	4	3	6	5
7	3	4	4	6	5
7	3	4	5	6	5
7	3	4	6	6	5
7	3	4	7	6	5
7	3	4	8	6	5
7	3	4	9	6	5
7	3	4	10	6	5
7	3	4	11	6	5
7	3	4	12	6	5
7	3	4	1	0	6
7	3	4	2	0	6
7	3	4	3	0	6
7	3	4	4	0	6
7	3	4	5	0	6
7	3	4	6	0	6
7	3	4	7	0	6
7	3	4	8	0	6
7	3	4	9	0	6
7	3	4	10	0	6
7	3	4	11	0	6
7	3	4	12	0	6
7	3	4	1	1	6
7	3	4	2	1	6
7	3	4	3	1	6
7	3	4	4	1	6
7	3	4	5	1	6
7	3	4	6	1	6
7	3	4	7	1	6
7	3	4	8	1	6
7	3	4	9	1	6
7	3	4	10	1	6
7	3	4	11	1	6
7	3	4	12	1	6
7	3	4	1	2	6
7	3	4	2	2	6
7	3	4	3	2	6
7	3	4	4	2	6
7	3	4	5	2	6
7	3	4	6	2	6
7	3	4	7	2	6
7	3	4	8	2	6
7	3	4	9	2	6
7	3	4	10	2	6
7	3	4	11	2	6
7	3	4	12	2	6
7	3	4	1	3	6
7	3	4	2	3	6
7	3	4	3	3	6
7	3	4	4	3	6
7	3	4	5	3	6
7	3	4	6	3	6
7	3	4	7	3	6
7	3	4	8	3	6
7	3	4	9	3	6
7	3	4	10	3	6
7	3	4	11	3	6
7	3	4	12	3	6
7	3	4	1	4	6
7	3	4	2	4	6
7	3	4	3	4	6
7	3	4	4	4	6
7	3	4	5	4	6
7	3	4	6	4	6
7	3	4	7	4	6
7	3	4	8	4	6
7	3	4	9	4	6
7	3	4	10	4	6
7	3	4	11	4	6
7	3	4	12	4	6
7	3	4	1	5	6
7	3	4	2	5	6
7	3	4	3	5	6
7	3	4	4	5	6
7	3	4	5	5	6
7	3	4	6	5	6
7	3	4	7	5	6
7	3	4	8	5	6
7	3	4	9	5	6
7	3	4	10	5	6
7	3	4	11	5	6
7	3	4	12	5	6
7	3	4	1	6	6
7	3	4	2	6	6
7	3	4	3	6	6
7	3	4	4	6	6
7	3	4	5	6	6
7	3	4	6	6	6
7	3	4	7	6	6
7	3	4	8	6	6
7	3	4	9	6	6
7	3	4	10	6	6
7	3	4	11	6	6
7	3	4	12	6	6
7	3	4	1	0	7
7	3	4	2	0	7
7	3	4	3	0	7
7	3	4	4	0	7
7	3	4	5	0	7
7	3	4	6	0	7
7	3	4	7	0	7
7	3	4	8	0	7
7	3	4	9	0	7
7	3	4	10	0	7
7	3	4	11	0	7
7	3	4	12	0	7
7	3	4	1	1	7
7	3	4	2	1	7
7	3	4	3	1	7
7	3	4	4	1	7
7	3	4	5	1	7
7	3	4	6	1	7
7	3	4	7	1	7
7	3	4	8	1	7
7	3	4	9	1	7
7	3	4	10	1	7
7	3	4	11	1	7
7	3	4	12	1	7
7	3	4	1	2	7
7	3	4	2	2	7
7	3	4	3	2	7
7	3	4	4	2	7
7	3	4	5	2	7
7	3	4	6	2	7
7	3	4	7	2	7
7	3	4	8	2	7
7	3	4	9	2	7
7	3	4	10	2	7
7	3	4	11	2	7
7	3	4	12	2	7
7	3	4	1	3	7
7	3	4	2	3	7
7	3	4	3	3	7
7	3	4	4	3	7
7	3	4	5	3	7
7	3	4	6	3	7
7	3	4	7	3	7
7	3	4	8	3	7
7	3	4	9	3	7
7	3	4	10	3	7
7	3	4	11	3	7
7	3	4	12	3	7
7	3	4	1	4	7
7	3	4	2	4	7
7	3	4	3	4	7
7	3	4	4	4	7
7	3	4	5	4	7
7	3	4	6	4	7
7	3	4	7	4	7
7	3	4	8	4	7
7	3	4	9	4	7
7	3	4	10	4	7
7	3	4	11	4	7
7	3	4	12	4	7
7	3	4	1	5	7
7	3	4	2	5	7
7	3	4	3	5	7
7	3	4	4	5	7
7	3	4	5	5	7
7	3	4	6	5	7
7	3	4	7	5	7
7	3	4	8	5	7
7	3	4	9	5	7
7	3	4	10	5	7
7	3	4	11	5	7
7	3	4	12	5	7
7	3	4	1	6	7
7	3	4	2	6	7
7	3	4	3	6	7
7	3	4	4	6	7
7	3	4	5	6	7
7	3	4	6	6	7
7	3	4	7	6	7
7	3	4	8	6	7
7	3	4	9	6	7
7	3	4	10	6	7
7	3	4	11	6	7
7	3	4	12	6	7
7	3	4	1	0	8
7	3	4	2	0	8
7	3	4	3	0	8
7	3	4	4	0	8
7	3	4	5	0	8
7	3	4	6	0	8
7	3	4	7	0	8
7	3	4	8	0	8
7	3	4	9	0	8
7	3	4	10	0	8
7	3	4	11	0	8
7	3	4	12	0	8
7	3	4	1	1	8
7	3	4	2	1	8
7	3	4	3	1	8
7	3	4	4	1	8
7	3	4	5	1	8
7	3	4	6	1	8
7	3	4	7	1	8
7	3	4	8	1	8
7	3	4	9	1	8
7	3	4	10	1	8
7	3	4	11	1	8
7	3	4	12	1	8
7	3	4	1	2	8
7	3	4	2	2	8
7	3	4	3	2	8
7	3	4	4	2	8
7	3	4	5	2	8
7	3	4	6	2	8
7	3	4	7	2	8
7	3	4	8	2	8
7	3	4	9	2	8
7	3	4	10	2	8
7	3	4	11	2	8
7	3	4	12	2	8
7	3	4	1	3	8
7	3	4	2	3	8
7	3	4	3	3	8
7	3	4	4	3	8
7	3	4	5	3	8
7	3	4	6	3	8
7	3	4	7	3	8
7	3	4	8	3	8
7	3	4	9	3	8
7	3	4	10	3	8
7	3	4	11	3	8
7	3	4	12	3	8
7	3	4	1	4	8
7	3	4	2	4	8
7	3	4	3	4	8
7	3	4	4	4	8
7	3	4	5	4	8
7	3	4	6	4	8
7	3	4	7	4	8
7	3	4	8	4	8
7	3	4	9	4	8
7	3	4	10	4	8
7	3	4	11	4	8
7	3	4	12	4	8
7	3	4	1	5	8
7	3	4	2	5	8
7	3	4	3	5	8
7	3	4	4	5	8
7	3	4	5	5	8
7	3	4	6	5	8
7	3	4	7	5	8
7	3	4	8	5	8
7	3	4	9	5	8
7	3	4	10	5	8
7	3	4	11	5	8
7	3	4	12	5	8
7	3	4	1	6	8
7	3	4	2	6	8
7	3	4	3	6	8
7	3	4	4	6	8
7	3	4	5	6	8
7	3	4	6	6	8
7	3	4	7	6	8
7	3	4	8	6	8
7	3	4	9	6	8
7	3	4	10	6	8
7	3	4	11	6	8
7	3	4	12	6	8
7	3	4	1	0	9
7	3	4	2	0	9
7	3	4	3	0	9
7	3	4	4	0	9
7	3	4	5	0	9
7	3	4	6	0	9
7	3	4	7	0	9
7	3	4	8	0	9
7	3	4	9	0	9
7	3	4	10	0	9
7	3	4	11	0	9
7	3	4	12	0	9
7	3	4	1	1	9
7	3	4	2	1	9
7	3	4	3	1	9
7	3	4	4	1	9
7	3	4	5	1	9
7	3	4	6	1	9
7	3	4	7	1	9
7	3	4	8	1	9
7	3	4	9	1	9
7	3	4	10	1	9
7	3	4	11	1	9
7	3	4	12	1	9
7	3	4	1	2	9
7	3	4	2	2	9
7	3	4	3	2	9
7	3	4	4	2	9
7	3	4	5	2	9
7	3	4	6	2	9
7	3	4	7	2	9
7	3	4	8	2	9
7	3	4	9	2	9
7	3	4	10	2	9
7	3	4	11	2	9
7	3	4	12	2	9
7	3	4	1	3	9
7	3	4	2	3	9
7	3	4	3	3	9
7	3	4	4	3	9
7	3	4	5	3	9
7	3	4	6	3	9
7	3	4	7	3	9
7	3	4	8	3	9
7	3	4	9	3	9
7	3	4	10	3	9
7	3	4	11	3	9
7	3	4	12	3	9
7	3	4	1	4	9
7	3	4	2	4	9
7	3	4	3	4	9
7	3	4	4	4	9
7	3	4	5	4	9
7	3	4	6	4	9
7	3	4	7	4	9
7	3	4	8	4	9
7	3	4	9	4	9
7	3	4	10	4	9
7	3	4	11	4	9
7	3	4	12	4	9
7	3	4	1	5	9
7	3	4	2	5	9
7	3	4	3	5	9
7	3	4	4	5	9
7	3	4	5	5	9
7	3	4	6	5	9
7	3	4	7	5	9
7	3	4	8	5	9
7	3	4	9	5	9
7	3	4	10	5	9
7	3	4	11	5	9
7	3	4	12	5	9
7	3	4	1	6	9
7	3	4	2	6	9
7	3	4	3	6	9
7	3	4	4	6	9
7	3	4	5	6	9
7	3	4	6	6	9
7	3	4	7	6	9
7	3	4	8	6	9
7	3	4	9	6	9
7	3	4	10	6	9
7	3	4	11	6	9
7	3	4	12	6	9
7	3	4	1	0	10
7	3	4	2	0	10
7	3	4	3	0	10
7	3	4	4	0	10
7	3	4	5	0	10
7	3	4	6	0	10
7	3	4	7	0	10
7	3	4	8	0	10
7	3	4	9	0	10
7	3	4	10	0	10
7	3	4	11	0	10
7	3	4	12	0	10
7	3	4	1	1	10
7	3	4	2	1	10
7	3	4	3	1	10
7	3	4	4	1	10
7	3	4	5	1	10
7	3	4	6	1	10
7	3	4	7	1	10
7	3	4	8	1	10
7	3	4	9	1	10
7	3	4	10	1	10
7	3	4	11	1	10
7	3	4	12	1	10
7	3	4	1	2	10
7	3	4	2	2	10
7	3	4	3	2	10
7	3	4	4	2	10
7	3	4	5	2	10
7	3	4	6	2	10
7	3	4	7	2	10
7	3	4	8	2	10
7	3	4	9	2	10
7	3	4	10	2	10
7	3	4	11	2	10
7	3	4	12	2	10
7	3	4	1	3	10
7	3	4	2	3	10
7	3	4	3	3	10
7	3	4	4	3	10
7	3	4	5	3	10
7	3	4	6	3	10
7	3	4	7	3	10
7	3	4	8	3	10
7	3	4	9	3	10
7	3	4	10	3	10
7	3	4	11	3	10
7	3	4	12	3	10
7	3	4	1	4	10
7	3	4	2	4	10
7	3	4	3	4	10
7	3	4	4	4	10
7	3	4	5	4	10
7	3	4	6	4	10
7	3	4	7	4	10
7	3	4	8	4	10
7	3	4	9	4	10
7	3	4	10	4	10
7	3	4	11	4	10
7	3	4	12	4	10
7	3	4	1	5	10
7	3	4	2	5	10
7	3	4	3	5	10
7	3	4	4	5	10
7	3	4	5	5	10
7	3	4	6	5	10
7	3	4	7	5	10
7	3	4	8	5	10
7	3	4	9	5	10
7	3	4	10	5	10
7	3	4	11	5	10
7	3	4	12	5	10
7	3	4	1	6	10
7	3	4	2	6	10
7	3	4	3	6	10
7	3	4	4	6	10
7	3	4	5	6	10
7	3	4	6	6	10
7	3	4	7	6	10
7	3	4	8	6	10
7	3	4	9	6	10
7	3	4	10	6	10
7	3	4	11	6	10
7	3	4	12	6	10
7	3	4	1	0	11
7	3	4	2	0	11
7	3	4	3	0	11
7	3	4	4	0	11
7	3	4	5	0	11
7	3	4	6	0	11
7	3	4	7	0	11
7	3	4	8	0	11
7	3	4	9	0	11
7	3	4	10	0	11
7	3	4	11	0	11
7	3	4	12	0	11
7	3	4	1	1	11
7	3	4	2	1	11
7	3	4	3	1	11
7	3	4	4	1	11
7	3	4	5	1	11
7	3	4	6	1	11
7	3	4	7	1	11
7	3	4	8	1	11
7	3	4	9	1	11
7	3	4	10	1	11
7	3	4	11	1	11
7	3	4	12	1	11
7	3	4	1	2	11
7	3	4	2	2	11
7	3	4	3	2	11
7	3	4	4	2	11
7	3	4	5	2	11
7	3	4	6	2	11
7	3	4	7	2	11
7	3	4	8	2	11
7	3	4	9	2	11
7	3	4	10	2	11
7	3	4	11	2	11
7	3	4	12	2	11
7	3	4	1	3	11
7	3	4	2	3	11
7	3	4	3	3	11
7	3	4	4	3	11
7	3	4	5	3	11
7	3	4	6	3	11
7	3	4	7	3	11
7	3	4	8	3	11
7	3	4	9	3	11
7	3	4	10	3	11
7	3	4	11	3	11
7	3	4	12	3	11
7	3	4	1	4	11
7	3	4	2	4	11
7	3	4	3	4	11
7	3	4	4	4	11
7	3	4	5	4	11
7	3	4	6	4	11
7	3	4	7	4	11
7	3	4	8	4	11
7	3	4	9	4	11
7	3	4	10	4	11
7	3	4	11	4	11
7	3	4	12	4	11
7	3	4	1	5	11
7	3	4	2	5	11
7	3	4	3	5	11
7	3	4	4	5	11
7	3	4	5	5	11
7	3	4	6	5	11
7	3	4	7	5	11
7	3	4	8	5	11
7	3	4	9	5	11
7	3	4	10	5	11
7	3	4	11	5	11
7	3	4	12	5	11
7	3	4	1	6	11
7	3	4	2	6	11
7	3	4	3	6	11
7	3	4	4	6	11
7	3	4	5	6	11
7	3	4	6	6	11
7	3	4	7	6	11
7	3	4	8	6	11
7	3	4	9	6	11
7	3	4	10	6	11
7	3	4	11	6	11
7	3	4	12	6	11
7	3	4	1	0	12
7	3	4	2	0	12
7	3	4	3	0	12
7	3	4	4	0	12
7	3	4	5	0	12
7	3	4	6	0	12
7	3	4	7	0	12
7	3	4	8	0	12
7	3	4	9	0	12
7	3	4	10	0	12
7	3	4	11	0	12
7	3	4	12	0	12
7	3	4	1	1	12
7	3	4	2	1	12
7	3	4	3	1	12
7	3	4	4	1	12
7	3	4	5	1	12
7	3	4	6	1	12
7	3	4	7	1	12
7	3	4	8	1	12
7	3	4	9	1	12
7	3	4	10	1	12
7	3	4	11	1	12
7	3	4	12	1	12
7	3	4	1	2	12
7	3	4	2	2	12
7	3	4	3	2	12
7	3	4	4	2	12
7	3	4	5	2	12
7	3	4	6	2	12
7	3	4	7	2	12
7	3	4	8	2	12
7	3	4	9	2	12
7	3	4	10	2	12
7	3	4	11	2	12
7	3	4	12	2	12
7	3	4	1	3	12
7	3	4	2	3	12
7	3	4	3	3	12
7	3	4	4	3	12
7	3	4	5	3	12
7	3	4	6	3	12
7	3	4	7	3	12
7	3	4	8	3	12
7	3	4	9	3	12
7	3	4	10	3	12
7	3	4	11	3	12
7	3	4	12	3	12
7	3	4	1	4	12
7	3	4	2	4	12
7	3	4	3	4	12
7	3	4	4	4	12
7	3	4	5	4	12
7	3	4	6	4	12
7	3	4	7	4	12
7	3	4	8	4	12
7	3	4	9	4	12
7	3	4	10	4	12
7	3	4	11	4	12
7	3	4	12	4	12
7	3	4	1	5	12
7	3	4	2	5	12
7	3	4	3	5	12
7	3	4	4	5	12
7	3	4	5	5	12
7	3	4	6	5	12
7	3	4	7	5	12
7	3	4	8	5	12
7	3	4	9	5	12
7	3	4	10	5	12
7	3	4	11	5	12
7	3	4	12	5	12
7	3	4	1	6	12
7	3	4	2	6	12
7	3	4	3	6	12
7	3	4	4	6	12
7	3	4	5	6	12
7	3	4	6	6	12
7	3	4	7	6	12
7	3	4	8	6	12
7	3	4	9	6	12
7	3	4	10	6	12
7	3	4	11	6	12
7	3	4	12	6	12
7	3	4	1	0	13
7	3	4	2	0	13
7	3	4	3	0	13
7	3	4	4	0	13
7	3	4	5	0	13
7	3	4	6	0	13
7	3	4	7	0	13
7	3	4	8	0	13
7	3	4	9	0	13
7	3	4	10	0	13
7	3	4	11	0	13
7	3	4	12	0	13
7	3	4	1	1	13
7	3	4	2	1	13
7	3	4	3	1	13
7	3	4	4	1	13
7	3	4	5	1	13
7	3	4	6	1	13
7	3	4	7	1	13
7	3	4	8	1	13
7	3	4	9	1	13
7	3	4	10	1	13
7	3	4	11	1	13
7	3	4	12	1	13
7	3	4	1	2	13
7	3	4	2	2	13
7	3	4	3	2	13
7	3	4	4	2	13
7	3	4	5	2	13
7	3	4	6	2	13
7	3	4	7	2	13
7	3	4	8	2	13
7	3	4	9	2	13
7	3	4	10	2	13
7	3	4	11	2	13
7	3	4	12	2	13
7	3	4	1	3	13
7	3	4	2	3	13
7	3	4	3	3	13
7	3	4	4	3	13
7	3	4	5	3	13
7	3	4	6	3	13
7	3	4	7	3	13
7	3	4	8	3	13
7	3	4	9	3	13
7	3	4	10	3	13
7	3	4	11	3	13
7	3	4	12	3	13
7	3	4	1	4	13
7	3	4	2	4	13
7	3	4	3	4	13
7	3	4	4	4	13
7	3	4	5	4	13
7	3	4	6	4	13
7	3	4	7	4	13
7	3	4	8	4	13
7	3	4	9	4	13
7	3	4	10	4	13
7	3	4	11	4	13
7	3	4	12	4	13
7	3	4	1	5	13
7	3	4	2	5	13
7	3	4	3	5	13
7	3	4	4	5	13
7	3	4	5	5	13
7	3	4	6	5	13
7	3	4	7	5	13
7	3	4	8	5	13
7	3	4	9	5	13
7	3	4	10	5	13
7	3	4	11	5	13
7	3	4	12	5	13
7	3	4	1	6	13
7	3	4	2	6	13
7	3	4	3	6	13
7	3	4	4	6	13
7	3	4	5	6	13
7	3	4	6	6	13
7	3	4	7	6	13
7	3	4	8	6	13
7	3	4	9	6	13
7	3	4	10	6	13
7	3	4	11	6	13
7	3	4	12	6	13
7	3	4	1	0	14
7	3	4	2	0	14
7	3	4	3	0	14
7	3	4	4	0	14
7	3	4	5	0	14
7	3	4	6	0	14
7	3	4	7	0	14
7	3	4	8	0	14
7	3	4	9	0	14
7	3	4	10	0	14
7	3	4	11	0	14
7	3	4	12	0	14
7	3	4	1	1	14
7	3	4	2	1	14
7	3	4	3	1	14
7	3	4	4	1	14
7	3	4	5	1	14
7	3	4	6	1	14
7	3	4	7	1	14
7	3	4	8	1	14
7	3	4	9	1	14
7	3	4	10	1	14
7	3	4	11	1	14
7	3	4	12	1	14
7	3	4	1	2	14
7	3	4	2	2	14
7	3	4	3	2	14
7	3	4	4	2	14
7	3	4	5	2	14
7	3	4	6	2	14
7	3	4	7	2	14
7	3	4	8	2	14
7	3	4	9	2	14
7	3	4	10	2	14
7	3	4	11	2	14
7	3	4	12	2	14
7	3	4	1	3	14
7	3	4	2	3	14
7	3	4	3	3	14
7	3	4	4	3	14
7	3	4	5	3	14
7	3	4	6	3	14
7	3	4	7	3	14
7	3	4	8	3	14
7	3	4	9	3	14
7	3	4	10	3	14
7	3	4	11	3	14
7	3	4	12	3	14
7	3	4	1	4	14
7	3	4	2	4	14
7	3	4	3	4	14
7	3	4	4	4	14
7	3	4	5	4	14
7	3	4	6	4	14
7	3	4	7	4	14
7	3	4	8	4	14
7	3	4	9	4	14
7	3	4	10	4	14
7	3	4	11	4	14
7	3	4	12	4	14
7	3	4	1	5	14
7	3	4	2	5	14
7	3	4	3	5	14
7	3	4	4	5	14
7	3	4	5	5	14
7	3	4	6	5	14
7	3	4	7	5	14
7	3	4	8	5	14
7	3	4	9	5	14
7	3	4	10	5	14
7	3	4	11	5	14
7	3	4	12	5	14
7	3	4	1	6	14
7	3	4	2	6	14
7	3	4	3	6	14
7	3	4	4	6	14
7	3	4	5	6	14
7	3	4	6	6	14
7	3	4	7	6	14
7	3	4	8	6	14
7	3	4	9	6	14
7	3	4	10	6	14
7	3	4	11	6	14
7	3	4	12	6	14
7	3	4	1	0	15
7	3	4	2	0	15
7	3	4	3	0	15
7	3	4	4	0	15
7	3	4	5	0	15
7	3	4	6	0	15
7	3	4	7	0	15
7	3	4	8	0	15
7	3	4	9	0	15
7	3	4	10	0	15
7	3	4	11	0	15
7	3	4	12	0	15
7	3	4	1	1	15
7	3	4	2	1	15
7	3	4	3	1	15
7	3	4	4	1	15
7	3	4	5	1	15
7	3	4	6	1	15
7	3	4	7	1	15
7	3	4	8	1	15
7	3	4	9	1	15
7	3	4	10	1	15
7	3	4	11	1	15
7	3	4	12	1	15
7	3	4	1	2	15
7	3	4	2	2	15
7	3	4	3	2	15
7	3	4	4	2	15
7	3	4	5	2	15
7	3	4	6	2	15
7	3	4	7	2	15
7	3	4	8	2	15
7	3	4	9	2	15
7	3	4	10	2	15
7	3	4	11	2	15
7	3	4	12	2	15
7	3	4	1	3	15
7	3	4	2	3	15
7	3	4	3	3	15
7	3	4	4	3	15
7	3	4	5	3	15
7	3	4	6	3	15
7	3	4	7	3	15
7	3	4	8	3	15
7	3	4	9	3	15
7	3	4	10	3	15
7	3	4	11	3	15
7	3	4	12	3	15
7	3	4	1	4	15
7	3	4	2	4	15
7	3	4	3	4	15
7	3	4	4	4	15
7	3	4	5	4	15
7	3	4	6	4	15
7	3	4	7	4	15
7	3	4	8	4	15
7	3	4	9	4	15
7	3	4	10	4	15
7	3	4	11	4	15
7	3	4	12	4	15
7	3	4	1	5	15
7	3	4	2	5	15
7	3	4	3	5	15
7	3	4	4	5	15
7	3	4	5	5	15
7	3	4	6	5	15
7	3	4	7	5	15
7	3	4	8	5	15
7	3	4	9	5	15
7	3	4	10	5	15
7	3	4	11	5	15
7	3	4	12	5	15
7	3	4	1	6	15
7	3	4	2	6	15
7	3	4	3	6	15
7	3	4	4	6	15
7	3	4	5	6	15
7	3	4	6	6	15
7	3	4	7	6	15
7	3	4	8	6	15
7	3	4	9	6	15
7	3	4	10	6	15
7	3	4	11	6	15
7	3	4	12	6	15
7	3	4	1	0	16
7	3	4	2	0	16
7	3	4	3	0	16
7	3	4	4	0	16
7	3	4	5	0	16
7	3	4	6	0	16
7	3	4	7	0	16
7	3	4	8	0	16
7	3	4	9	0	16
7	3	4	10	0	16
7	3	4	11	0	16
7	3	4	12	0	16
7	3	4	1	1	16
7	3	4	2	1	16
7	3	4	3	1	16
7	3	4	4	1	16
7	3	4	5	1	16
7	3	4	6	1	16
7	3	4	7	1	16
7	3	4	8	1	16
7	3	4	9	1	16
7	3	4	10	1	16
7	3	4	11	1	16
7	3	4	12	1	16
7	3	4	1	2	16
7	3	4	2	2	16
7	3	4	3	2	16
7	3	4	4	2	16
7	3	4	5	2	16
7	3	4	6	2	16
7	3	4	7	2	16
7	3	4	8	2	16
7	3	4	9	2	16
7	3	4	10	2	16
7	3	4	11	2	16
7	3	4	12	2	16
7	3	4	1	3	16
7	3	4	2	3	16
7	3	4	3	3	16
7	3	4	4	3	16
7	3	4	5	3	16
7	3	4	6	3	16
7	3	4	7	3	16
7	3	4	8	3	16
7	3	4	9	3	16
7	3	4	10	3	16
7	3	4	11	3	16
7	3	4	12	3	16
7	3	4	1	4	16
7	3	4	2	4	16
7	3	4	3	4	16
7	3	4	4	4	16
7	3	4	5	4	16
7	3	4	6	4	16
7	3	4	7	4	16
7	3	4	8	4	16
7	3	4	9	4	16
7	3	4	10	4	16
7	3	4	11	4	16
7	3	4	12	4	16
7	3	4	1	5	16
7	3	4	2	5	16
7	3	4	3	5	16
7	3	4	4	5	16
7	3	4	5	5	16
7	3	4	6	5	16
7	3	4	7	5	16
7	3	4	8	5	16
7	3	4	9	5	16
7	3	4	10	5	16
7	3	4	11	5	16
7	3	4	12	5	16
7	3	4	1	6	16
7	3	4	2	6	16
7	3	4	3	6	16
7	3	4	4	6	16
7	3	4	5	6	16
7	3	4	6	6	16
7	3	4	7	6	16
7	3	4	8	6	16
7	3	4	9	6	16
7	3	4	10	6	16
7	3	4	11	6	16
7	3	4	12	6	16
7	3	4	1	0	17
7	3	4	2	0	17
7	3	4	3	0	17
7	3	4	4	0	17
7	3	4	5	0	17
7	3	4	6	0	17
7	3	4	7	0	17
7	3	4	8	0	17
7	3	4	9	0	17
7	3	4	10	0	17
7	3	4	11	0	17
7	3	4	12	0	17
7	3	4	1	1	17
7	3	4	2	1	17
7	3	4	3	1	17
7	3	4	4	1	17
7	3	4	5	1	17
7	3	4	6	1	17
7	3	4	7	1	17
7	3	4	8	1	17
7	3	4	9	1	17
7	3	4	10	1	17
7	3	4	11	1	17
7	3	4	12	1	17
7	3	4	1	2	17
7	3	4	2	2	17
7	3	4	3	2	17
7	3	4	4	2	17
7	3	4	5	2	17
7	3	4	6	2	17
7	3	4	7	2	17
7	3	4	8	2	17
7	3	4	9	2	17
7	3	4	10	2	17
7	3	4	11	2	17
7	3	4	12	2	17
7	3	4	1	3	17
7	3	4	2	3	17
7	3	4	3	3	17
7	3	4	4	3	17
7	3	4	5	3	17
7	3	4	6	3	17
7	3	4	7	3	17
7	3	4	8	3	17
7	3	4	9	3	17
7	3	4	10	3	17
7	3	4	11	3	17
7	3	4	12	3	17
7	3	4	1	4	17
7	3	4	2	4	17
7	3	4	3	4	17
7	3	4	4	4	17
7	3	4	5	4	17
7	3	4	6	4	17
7	3	4	7	4	17
7	3	4	8	4	17
7	3	4	9	4	17
7	3	4	10	4	17
7	3	4	11	4	17
7	3	4	12	4	17
7	3	4	1	5	17
7	3	4	2	5	17
7	3	4	3	5	17
7	3	4	4	5	17
7	3	4	5	5	17
7	3	4	6	5	17
7	3	4	7	5	17
7	3	4	8	5	17
7	3	4	9	5	17
7	3	4	10	5	17
7	3	4	11	5	17
7	3	4	12	5	17
7	3	4	1	6	17
7	3	4	2	6	17
7	3	4	3	6	17
7	3	4	4	6	17
7	3	4	5	6	17
7	3	4	6	6	17
7	3	4	7	6	17
7	3	4	8	6	17
7	3	4	9	6	17
7	3	4	10	6	17
7	3	4	11	6	17
7	3	4	12	6	17
7	3	4	1	0	18
7	3	4	2	0	18
7	3	4	3	0	18
7	3	4	4	0	18
7	3	4	5	0	18
7	3	4	6	0	18
7	3	4	7	0	18
7	3	4	8	0	18
7	3	4	9	0	18
7	3	4	10	0	18
7	3	4	11	0	18
7	3	4	12	0	18
7	3	4	1	1	18
7	3	4	2	1	18
7	3	4	3	1	18
7	3	4	4	1	18
7	3	4	5	1	18
7	3	4	6	1	18
7	3	4	7	1	18
7	3	4	8	1	18
7	3	4	9	1	18
7	3	4	10	1	18
7	3	4	11	1	18
7	3	4	12	1	18
7	3	4	1	2	18
7	3	4	2	2	18
7	3	4	3	2	18
7	3	4	4	2	18
7	3	4	5	2	18
7	3	4	6	2	18
7	3	4	7	2	18
7	3	4	8	2	18
7	3	4	9	2	18
7	3	4	10	2	18
7	3	4	11	2	18
7	3	4	12	2	18
7	3	4	1	3	18
7	3	4	2	3	18
7	3	4	3	3	18
7	3	4	4	3	18
7	3	4	5	3	18
7	3	4	6	3	18
7	3	4	7	3	18
7	3	4	8	3	18
7	3	4	9	3	18
7	3	4	10	3	18
7	3	4	11	3	18
7	3	4	12	3	18
7	3	4	1	4	18
7	3	4	2	4	18
7	3	4	3	4	18
7	3	4	4	4	18
7	3	4	5	4	18
7	3	4	6	4	18
7	3	4	7	4	18
7	3	4	8	4	18
7	3	4	9	4	18
7	3	4	10	4	18
7	3	4	11	4	18
7	3	4	12	4	18
7	3	4	1	5	18
7	3	4	2	5	18
7	3	4	3	5	18
7	3	4	4	5	18
7	3	4	5	5	18
7	3	4	6	5	18
7	3	4	7	5	18
7	3	4	8	5	18
7	3	4	9	5	18
7	3	4	10	5	18
7	3	4	11	5	18
7	3	4	12	5	18
7	3	4	1	6	18
7	3	4	2	6	18
7	3	4	3	6	18
7	3	4	4	6	18
7	3	4	5	6	18
7	3	4	6	6	18
7	3	4	7	6	18
7	3	4	8	6	18
7	3	4	9	6	18
7	3	4	10	6	18
7	3	4	11	6	18
7	3	4	12	6	18
7	3	4	1	0	19
7	3	4	2	0	19
7	3	4	3	0	19
7	3	4	4	0	19
7	3	4	5	0	19
7	3	4	6	0	19
7	3	4	7	0	19
7	3	4	8	0	19
7	3	4	9	0	19
7	3	4	10	0	19
7	3	4	11	0	19
7	3	4	12	0	19
7	3	4	1	1	19
7	3	4	2	1	19
7	3	4	3	1	19
7	3	4	4	1	19
7	3	4	5	1	19
7	3	4	6	1	19
7	3	4	7	1	19
7	3	4	8	1	19
7	3	4	9	1	19
7	3	4	10	1	19
7	3	4	11	1	19
7	3	4	12	1	19
7	3	4	1	2	19
7	3	4	2	2	19
7	3	4	3	2	19
7	3	4	4	2	19
7	3	4	5	2	19
7	3	4	6	2	19
7	3	4	7	2	19
7	3	4	8	2	19
7	3	4	9	2	19
7	3	4	10	2	19
7	3	4	11	2	19
7	3	4	12	2	19
7	3	4	1	3	19
7	3	4	2	3	19
7	3	4	3	3	19
7	3	4	4	3	19
7	3	4	5	3	19
7	3	4	6	3	19
7	3	4	7	3	19
7	3	4	8	3	19
7	3	4	9	3	19
7	3	4	10	3	19
7	3	4	11	3	19
7	3	4	12	3	19
7	3	4	1	4	19
7	3	4	2	4	19
7	3	4	3	4	19
7	3	4	4	4	19
7	3	4	5	4	19
7	3	4	6	4	19
7	3	4	7	4	19
7	3	4	8	4	19
7	3	4	9	4	19
7	3	4	10	4	19
7	3	4	11	4	19
7	3	4	12	4	19
7	3	4	1	5	19
7	3	4	2	5	19
7	3	4	3	5	19
7	3	4	4	5	19
7	3	4	5	5	19
7	3	4	6	5	19
7	3	4	7	5	19
7	3	4	8	5	19
7	3	4	9	5	19
7	3	4	10	5	19
7	3	4	11	5	19
7	3	4	12	5	19
7	3	4	1	6	19
7	3	4	2	6	19
7	3	4	3	6	19
7	3	4	4	6	19
7	3	4	5	6	19
7	3	4	6	6	19
7	3	4	7	6	19
7	3	4	8	6	19
7	3	4	9	6	19
7	3	4	10	6	19
7	3	4	11	6	19
7	3	4	12	6	19
7	3	4	1	0	20
7	3	4	2	0	20
7	3	4	3	0	20
7	3	4	4	0	20
7	3	4	5	0	20
7	3	4	6	0	20
7	3	4	7	0	20
7	3	4	8	0	20
7	3	4	9	0	20
7	3	4	10	0	20
7	3	4	11	0	20
7	3	4	12	0	20
7	3	4	1	1	20
7	3	4	2	1	20
7	3	4	3	1	20
7	3	4	4	1	20
7	3	4	5	1	20
7	3	4	6	1	20
7	3	4	7	1	20
7	3	4	8	1	20
7	3	4	9	1	20
7	3	4	10	1	20
7	3	4	11	1	20
7	3	4	12	1	20
7	3	4	1	2	20
7	3	4	2	2	20
7	3	4	3	2	20
7	3	4	4	2	20
7	3	4	5	2	20
7	3	4	6	2	20
7	3	4	7	2	20
7	3	4	8	2	20
7	3	4	9	2	20
7	3	4	10	2	20
7	3	4	11	2	20
7	3	4	12	2	20
7	3	4	1	3	20
7	3	4	2	3	20
7	3	4	3	3	20
7	3	4	4	3	20
7	3	4	5	3	20
7	3	4	6	3	20
7	3	4	7	3	20
7	3	4	8	3	20
7	3	4	9	3	20
7	3	4	10	3	20
7	3	4	11	3	20
7	3	4	12	3	20
7	3	4	1	4	20
7	3	4	2	4	20
7	3	4	3	4	20
7	3	4	4	4	20
7	3	4	5	4	20
7	3	4	6	4	20
7	3	4	7	4	20
7	3	4	8	4	20
7	3	4	9	4	20
7	3	4	10	4	20
7	3	4	11	4	20
7	3	4	12	4	20
7	3	4	1	5	20
7	3	4	2	5	20
7	3	4	3	5	20
7	3	4	4	5	20
7	3	4	5	5	20
7	3	4	6	5	20
7	3	4	7	5	20
7	3	4	8	5	20
7	3	4	9	5	20
7	3	4	10	5	20
7	3	4	11	5	20
7	3	4	12	5	20
7	3	4	1	6	20
7	3	4	2	6	20
7	3	4	3	6	20
7	3	4	4	6	20
7	3	4	5	6	20
7	3	4	6	6	20
7	3	4	7	6	20
7	3	4	8	6	20
7	3	4	9	6	20
7	3	4	10	6	20
7	3	4	11	6	20
7	3	4	12	6	20
7	3	4	1	0	21
7	3	4	2	0	21
7	3	4	3	0	21
7	3	4	4	0	21
7	3	4	5	0	21
7	3	4	6	0	21
7	3	4	7	0	21
7	3	4	8	0	21
7	3	4	9	0	21
7	3	4	10	0	21
7	3	4	11	0	21
7	3	4	12	0	21
7	3	4	1	1	21
7	3	4	2	1	21
7	3	4	3	1	21
7	3	4	4	1	21
7	3	4	5	1	21
7	3	4	6	1	21
7	3	4	7	1	21
7	3	4	8	1	21
7	3	4	9	1	21
7	3	4	10	1	21
7	3	4	11	1	21
7	3	4	12	1	21
7	3	4	1	2	21
7	3	4	2	2	21
7	3	4	3	2	21
7	3	4	4	2	21
7	3	4	5	2	21
7	3	4	6	2	21
7	3	4	7	2	21
7	3	4	8	2	21
7	3	4	9	2	21
7	3	4	10	2	21
7	3	4	11	2	21
7	3	4	12	2	21
7	3	4	1	3	21
7	3	4	2	3	21
7	3	4	3	3	21
7	3	4	4	3	21
7	3	4	5	3	21
7	3	4	6	3	21
7	3	4	7	3	21
7	3	4	8	3	21
7	3	4	9	3	21
7	3	4	10	3	21
7	3	4	11	3	21
7	3	4	12	3	21
7	3	4	1	4	21
7	3	4	2	4	21
7	3	4	3	4	21
7	3	4	4	4	21
7	3	4	5	4	21
7	3	4	6	4	21
7	3	4	7	4	21
7	3	4	8	4	21
7	3	4	9	4	21
7	3	4	10	4	21
7	3	4	11	4	21
7	3	4	12	4	21
7	3	4	1	5	21
7	3	4	2	5	21
7	3	4	3	5	21
7	3	4	4	5	21
7	3	4	5	5	21
7	3	4	6	5	21
7	3	4	7	5	21
7	3	4	8	5	21
7	3	4	9	5	21
7	3	4	10	5	21
7	3	4	11	5	21
7	3	4	12	5	21
7	3	4	1	6	21
7	3	4	2	6	21
7	3	4	3	6	21
7	3	4	4	6	21
7	3	4	5	6	21
7	3	4	6	6	21
7	3	4	7	6	21
7	3	4	8	6	21
7	3	4	9	6	21
7	3	4	10	6	21
7	3	4	11	6	21
7	3	4	12	6	21
7	3	4	1	0	22
7	3	4	2	0	22
7	3	4	3	0	22
7	3	4	4	0	22
7	3	4	5	0	22
7	3	4	6	0	22
7	3	4	7	0	22
7	3	4	8	0	22
7	3	4	9	0	22
7	3	4	10	0	22
7	3	4	11	0	22
7	3	4	12	0	22
7	3	4	1	1	22
7	3	4	2	1	22
7	3	4	3	1	22
7	3	4	4	1	22
7	3	4	5	1	22
7	3	4	6	1	22
7	3	4	7	1	22
7	3	4	8	1	22
7	3	4	9	1	22
7	3	4	10	1	22
7	3	4	11	1	22
7	3	4	12	1	22
7	3	4	1	2	22
7	3	4	2	2	22
7	3	4	3	2	22
7	3	4	4	2	22
7	3	4	5	2	22
7	3	4	6	2	22
7	3	4	7	2	22
7	3	4	8	2	22
7	3	4	9	2	22
7	3	4	10	2	22
7	3	4	11	2	22
7	3	4	12	2	22
7	3	4	1	3	22
7	3	4	2	3	22
7	3	4	3	3	22
7	3	4	4	3	22
7	3	4	5	3	22
7	3	4	6	3	22
7	3	4	7	3	22
7	3	4	8	3	22
7	3	4	9	3	22
7	3	4	10	3	22
7	3	4	11	3	22
7	3	4	12	3	22
7	3	4	1	4	22
7	3	4	2	4	22
7	3	4	3	4	22
7	3	4	4	4	22
7	3	4	5	4	22
7	3	4	6	4	22
7	3	4	7	4	22
7	3	4	8	4	22
7	3	4	9	4	22
7	3	4	10	4	22
7	3	4	11	4	22
7	3	4	12	4	22
7	3	4	1	5	22
7	3	4	2	5	22
7	3	4	3	5	22
7	3	4	4	5	22
7	3	4	5	5	22
7	3	4	6	5	22
7	3	4	7	5	22
7	3	4	8	5	22
7	3	4	9	5	22
7	3	4	10	5	22
7	3	4	11	5	22
7	3	4	12	5	22
7	3	4	1	6	22
7	3	4	2	6	22
7	3	4	3	6	22
7	3	4	4	6	22
7	3	4	5	6	22
7	3	4	6	6	22
7	3	4	7	6	22
7	3	4	8	6	22
7	3	4	9	6	22
7	3	4	10	6	22
7	3	4	11	6	22
7	3	4	12	6	22
7	3	4	1	0	23
7	3	4	2	0	23
7	3	4	3	0	23
7	3	4	4	0	23
7	3	4	5	0	23
7	3	4	6	0	23
7	3	4	7	0	23
7	3	4	8	0	23
7	3	4	9	0	23
7	3	4	10	0	23
7	3	4	11	0	23
7	3	4	12	0	23
7	3	4	1	1	23
7	3	4	2	1	23
7	3	4	3	1	23
7	3	4	4	1	23
7	3	4	5	1	23
7	3	4	6	1	23
7	3	4	7	1	23
7	3	4	8	1	23
7	3	4	9	1	23
7	3	4	10	1	23
7	3	4	11	1	23
7	3	4	12	1	23
7	3	4	1	2	23
7	3	4	2	2	23
7	3	4	3	2	23
7	3	4	4	2	23
7	3	4	5	2	23
7	3	4	6	2	23
7	3	4	7	2	23
7	3	4	8	2	23
7	3	4	9	2	23
7	3	4	10	2	23
7	3	4	11	2	23
7	3	4	12	2	23
7	3	4	1	3	23
7	3	4	2	3	23
7	3	4	3	3	23
7	3	4	4	3	23
7	3	4	5	3	23
7	3	4	6	3	23
7	3	4	7	3	23
7	3	4	8	3	23
7	3	4	9	3	23
7	3	4	10	3	23
7	3	4	11	3	23
7	3	4	12	3	23
7	3	4	1	4	23
7	3	4	2	4	23
7	3	4	3	4	23
7	3	4	4	4	23
7	3	4	5	4	23
7	3	4	6	4	23
7	3	4	7	4	23
7	3	4	8	4	23
7	3	4	9	4	23
7	3	4	10	4	23
7	3	4	11	4	23
7	3	4	12	4	23
7	3	4	1	5	23
7	3	4	2	5	23
7	3	4	3	5	23
7	3	4	4	5	23
7	3	4	5	5	23
7	3	4	6	5	23
7	3	4	7	5	23
7	3	4	8	5	23
7	3	4	9	5	23
7	3	4	10	5	23
7	3	4	11	5	23
7	3	4	12	5	23
7	3	4	1	6	23
7	3	4	2	6	23
7	3	4	3	6	23
7	3	4	4	6	23
7	3	4	5	6	23
7	3	4	6	6	23
7	3	4	7	6	23
7	3	4	8	6	23
7	3	4	9	6	23
7	3	4	10	6	23
7	3	4	11	6	23
7	3	4	12	6	23
\.

COPY tariff_dev_v2.tou_pattern_groups (pattern_detail_id, description) FROM stdin;
4	Eskom TOU for 2024 cycle
5	Eskom TOU for 2025 cycle
7	Flat (v2): every hour All Year / All Periods
\.

COPY tariff_dev_v2.tou_patterns (pattern_class_id, pattern_name, created_on, description) FROM stdin;
1	Eskom Standard Three Period TOU	2026-04-16	This is the TOU class with three periods: Peak, Standard and Off Peak
2	mining Seasonal 	2026-08-11	This is a season based tariff with a high and low season. It has a single period in each season with a basic flat rate.
3	Flat	2026-11-14	v2: every hour of the year is season All Year, period All Periods. Used by every non-TOU rate.
4	Seasonal Flat	2026-11-19	v2: a high and a low season, one period (All Periods) every hour. Used by seasonal non-TOU rates.
\.

COPY tariff_dev_v2.tou_periods (period_id, period_name) FROM stdin;
1	Peak
2	Standard
3	Off Peak
4	All Periods
\.

COPY tariff_dev_v2.tou_seasons (season_id, season_name) FROM stdin;
1	High Season
2	Low Season
3	All Year
\.



--
-- TOC entry 12011 (class 0 OID 0)
-- Dependencies: 2216
-- Name: attribute_collections_attribute_collection_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.attribute_collections_attribute_collection_id_seq', 46, true);


--
-- TOC entry 12012 (class 0 OID 0)
-- Dependencies: 2213
-- Name: attribute_values_attribute_value_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.attribute_values_attribute_value_id_seq', 30, true);


--
-- TOC entry 12013 (class 0 OID 0)
-- Dependencies: 2211
-- Name: attributes_attribute_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.attributes_attribute_id_seq', 5, true);


--
-- TOC entry 12014 (class 0 OID 0)
-- Dependencies: 2236
-- Name: implementation_signatures_signature_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.implementation_signatures_signature_id_seq', 532, true);


--
-- TOC entry 12015 (class 0 OID 0)
-- Dependencies: 2208
-- Name: rate_classes_rate_class_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.rate_classes_rate_class_id_seq', 59, true);


--
-- TOC entry 12016 (class 0 OID 0)
-- Dependencies: 2234
-- Name: rate_operations_operation_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.rate_operations_operation_id_seq', 38, true);


--
-- TOC entry 12017 (class 0 OID 0)
-- Dependencies: 2232
-- Name: rates_rate_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.rates_rate_id_seq', 2375, true);


--
-- TOC entry 12018 (class 0 OID 0)
-- Dependencies: 2230
-- Name: tariff_tou_pattern_link_link_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.tariff_tou_pattern_link_link_id_seq', 323, true);


--
-- TOC entry 12019 (class 0 OID 0)
-- Dependencies: 2206
-- Name: tariffs_tariff_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.tariffs_tariff_id_seq', 49, true);


--
-- TOC entry 12020 (class 0 OID 0)
-- Dependencies: 2227
-- Name: tou_pattern_groups_pattern_detail_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.tou_pattern_groups_pattern_detail_id_seq', 9, true);


--
-- TOC entry 12021 (class 0 OID 0)
-- Dependencies: 2225
-- Name: tou_patterns_pattern_class_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.tou_patterns_pattern_class_id_seq', 4, true);


--
-- TOC entry 12022 (class 0 OID 0)
-- Dependencies: 2219
-- Name: tou_periods_period_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.tou_periods_period_id_seq', 5, false);


--
-- TOC entry 12023 (class 0 OID 0)
-- Dependencies: 2221
-- Name: tou_seasons_season_id_seq; Type: SEQUENCE SET; Schema: tariff_dev_v2; Owner: -
--

SELECT pg_catalog.setval('tariff_dev_v2.tou_seasons_season_id_seq', 4, false);


--
-- TOC entry 11690 (class 2606 OID 180042709)
-- Name: attribute_collection_values attribute_collection_values_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_collection_values
    ADD CONSTRAINT attribute_collection_values_pkey PRIMARY KEY (attribute_collection_id, attribute_id);


--
-- TOC entry 11686 (class 2606 OID 180042701)
-- Name: attribute_collections attribute_collections_attribute_value_ids_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_collections
    ADD CONSTRAINT attribute_collections_attribute_value_ids_key UNIQUE (attribute_value_ids);


--
-- TOC entry 11688 (class 2606 OID 180042699)
-- Name: attribute_collections attribute_collections_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_collections
    ADD CONSTRAINT attribute_collections_pkey PRIMARY KEY (attribute_collection_id);


--
-- TOC entry 11678 (class 2606 OID 180042665)
-- Name: attribute_values attribute_values_attribute_id_attribute_value_id_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_values
    ADD CONSTRAINT attribute_values_attribute_id_attribute_value_id_key UNIQUE (attribute_id, attribute_value_id);


--
-- TOC entry 11680 (class 2606 OID 180042663)
-- Name: attribute_values attribute_values_attribute_id_value_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_values
    ADD CONSTRAINT attribute_values_attribute_id_value_key UNIQUE (attribute_id, value);


--
-- TOC entry 11682 (class 2606 OID 180042661)
-- Name: attribute_values attribute_values_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_values
    ADD CONSTRAINT attribute_values_pkey PRIMARY KEY (attribute_value_id);


--
-- TOC entry 11672 (class 2606 OID 180042648)
-- Name: attributes attributes_attribute_code_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attributes
    ADD CONSTRAINT attributes_attribute_code_key UNIQUE (attribute_code);


--
-- TOC entry 11674 (class 2606 OID 180042650)
-- Name: attributes attributes_attribute_column_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attributes
    ADD CONSTRAINT attributes_attribute_column_key UNIQUE (attribute_column);


--
-- TOC entry 11676 (class 2606 OID 180042646)
-- Name: attributes attributes_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attributes
    ADD CONSTRAINT attributes_pkey PRIMARY KEY (attribute_id);


--
-- TOC entry 11658 (class 2606 OID 180042569)
-- Name: countries countries_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.countries
    ADD CONSTRAINT countries_pkey PRIMARY KEY (country_code);


--
-- TOC entry 11660 (class 2606 OID 180042578)
-- Name: currencies currencies_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.currencies
    ADD CONSTRAINT currencies_pkey PRIMARY KEY (currency_code);


--
-- TOC entry 11739 (class 2606 OID 180053883)
-- Name: holiday_scheme_days holiday_scheme_days_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.holiday_scheme_days
    ADD CONSTRAINT holiday_scheme_days_pkey PRIMARY KEY (holiday_scheme_id, holiday_date);


--
-- TOC entry 11735 (class 2606 OID 180053872)
-- Name: holiday_schemes holiday_schemes_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.holiday_schemes
    ADD CONSTRAINT holiday_schemes_pkey PRIMARY KEY (holiday_scheme_id);


--
-- TOC entry 11737 (class 2606 OID 180053874)
-- Name: holiday_schemes holiday_schemes_scheme_key_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.holiday_schemes
    ADD CONSTRAINT holiday_schemes_scheme_key_key UNIQUE (scheme_key);


--
-- TOC entry 11727 (class 2606 OID 180042948)
-- Name: implementation_signatures implementation_signatures_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.implementation_signatures
    ADD CONSTRAINT implementation_signatures_pkey PRIMARY KEY (signature_id);


--
-- TOC entry 11733 (class 2606 OID 180053862)
-- Name: public_holidays public_holidays_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.public_holidays
    ADD CONSTRAINT public_holidays_pkey PRIMARY KEY (holiday_date);


--
-- TOC entry 11684 (class 2606 OID 180042677)
-- Name: rate_class_attributes rate_class_attributes_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_attributes
    ADD CONSTRAINT rate_class_attributes_pkey PRIMARY KEY (rate_class_id, attribute_id);


--
-- TOC entry 11729 (class 2606 OID 180042958)
-- Name: rate_class_operation_implementation rate_class_operation_implementation_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_operation_implementation
    ADD CONSTRAINT rate_class_operation_implementation_pkey PRIMARY KEY (rate_class_id, operation_id);


--
-- TOC entry 11700 (class 2606 OID 180042752)
-- Name: rate_class_tou_periods rate_class_tou_periods_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_tou_periods
    ADD CONSTRAINT rate_class_tou_periods_pkey PRIMARY KEY (rate_class_id, period_id);


--
-- TOC entry 11702 (class 2606 OID 180042771)
-- Name: rate_class_tou_seasons rate_class_tou_seasons_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_tou_seasons
    ADD CONSTRAINT rate_class_tou_seasons_pkey PRIMARY KEY (rate_class_id, season_id);


--
-- TOC entry 11664 (class 2606 OID 180042614)
-- Name: rate_classes rate_classes_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_classes
    ADD CONSTRAINT rate_classes_pkey PRIMARY KEY (rate_class_id);


--
-- TOC entry 11666 (class 2606 OID 180042616)
-- Name: rate_classes rate_classes_rate_key_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_classes
    ADD CONSTRAINT rate_classes_rate_key_key UNIQUE (rate_key);


--
-- TOC entry 11723 (class 2606 OID 180042937)
-- Name: rate_operations rate_operations_operation_key_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_operations
    ADD CONSTRAINT rate_operations_operation_key_key UNIQUE (operation_key);


--
-- TOC entry 11725 (class 2606 OID 180042935)
-- Name: rate_operations rate_operations_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_operations
    ADD CONSTRAINT rate_operations_pkey PRIMARY KEY (operation_id);


--
-- TOC entry 11719 (class 2606 OID 181673764)
-- Name: rates rates_no_overlap; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_no_overlap EXCLUDE USING gist (tariff_id WITH =, rate_class_id WITH =, pattern_class_id WITH =, attribute_collection_id WITH =, season_id WITH =, period_id WITH =, block_from WITH =, daterange(valid_from, valid_to, '[]'::text) WITH &&);


--
-- TOC entry 11721 (class 2606 OID 180042891)
-- Name: rates rates_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_pkey PRIMARY KEY (rate_id);


--
-- TOC entry 11731 (class 2606 OID 180043231)
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- TOC entry 11668 (class 2606 OID 180043611)
-- Name: tariff_rate_classes tariff_rate_classes_no_overlap; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_rate_classes
    ADD CONSTRAINT tariff_rate_classes_no_overlap EXCLUDE USING gist (tariff_id WITH =, rate_class_id WITH =, daterange(valid_from, valid_to, '[]'::text) WITH &&);


--
-- TOC entry 11670 (class 2606 OID 180042625)
-- Name: tariff_rate_classes tariff_rate_classes_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_rate_classes
    ADD CONSTRAINT tariff_rate_classes_pkey PRIMARY KEY (tariff_id, rate_class_id, valid_from);


--
-- TOC entry 11712 (class 2606 OID 180042850)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_no_overlap; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_no_overlap EXCLUDE USING gist (tariff_id WITH =, rate_class_id WITH =, daterange(valid_from, valid_to, '[]'::text) WITH &&);


--
-- TOC entry 11714 (class 2606 OID 180042846)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_pkey PRIMARY KEY (link_id);


--
-- TOC entry 11716 (class 2606 OID 180042848)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_tariff_id_rate_class_id_valid_from_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_tariff_id_rate_class_id_valid_from_key UNIQUE (tariff_id, rate_class_id, valid_from);


--
-- TOC entry 11662 (class 2606 OID 180042590)
-- Name: tariffs tariffs_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariffs
    ADD CONSTRAINT tariffs_pkey PRIMARY KEY (tariff_id);


--
-- TOC entry 11710 (class 2606 OID 180042818)
-- Name: tou_pattern_detail tou_pattern_detail_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_pattern_detail
    ADD CONSTRAINT tou_pattern_detail_pkey PRIMARY KEY (pattern_detail_id, month, dow, hour);


--
-- TOC entry 11708 (class 2606 OID 180042804)
-- Name: tou_pattern_groups tou_pattern_groups_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_pattern_groups
    ADD CONSTRAINT tou_pattern_groups_pkey PRIMARY KEY (pattern_detail_id);


--
-- TOC entry 11704 (class 2606 OID 180042795)
-- Name: tou_patterns tou_patterns_pattern_name_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_patterns
    ADD CONSTRAINT tou_patterns_pattern_name_key UNIQUE (pattern_name);


--
-- TOC entry 11706 (class 2606 OID 180042793)
-- Name: tou_patterns tou_patterns_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_patterns
    ADD CONSTRAINT tou_patterns_pkey PRIMARY KEY (pattern_class_id);


--
-- TOC entry 11692 (class 2606 OID 180042731)
-- Name: tou_periods tou_periods_period_name_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_periods
    ADD CONSTRAINT tou_periods_period_name_key UNIQUE (period_name);


--
-- TOC entry 11694 (class 2606 OID 180042729)
-- Name: tou_periods tou_periods_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_periods
    ADD CONSTRAINT tou_periods_pkey PRIMARY KEY (period_id);


--
-- TOC entry 11696 (class 2606 OID 180042741)
-- Name: tou_seasons tou_seasons_pkey; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_seasons
    ADD CONSTRAINT tou_seasons_pkey PRIMARY KEY (season_id);


--
-- TOC entry 11698 (class 2606 OID 180042743)
-- Name: tou_seasons tou_seasons_season_name_key; Type: CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_seasons
    ADD CONSTRAINT tou_seasons_season_name_key UNIQUE (season_name);


--
-- TOC entry 11717 (class 1259 OID 180042924)
-- Name: rates_lookup_idx; Type: INDEX; Schema: tariff_dev_v2; Owner: -
--

CREATE INDEX rates_lookup_idx ON tariff_dev_v2.rates USING btree (rate_class_id, tariff_id, attribute_collection_id, valid_from);


--
-- TOC entry 11775 (class 2620 OID 180043265)
-- Name: attribute_collection_values attribute_collection_values_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER attribute_collection_values_check AFTER INSERT OR DELETE OR UPDATE ON tariff_dev_v2.attribute_collection_values DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_attribute_collection_values_check();


--
-- TOC entry 11774 (class 2620 OID 180043263)
-- Name: attribute_collections attribute_collections_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER attribute_collections_check AFTER INSERT OR UPDATE OF attribute_value_ids ON tariff_dev_v2.attribute_collections DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_attribute_collections_check();


--
-- TOC entry 11773 (class 2620 OID 180043261)
-- Name: rate_class_attributes rate_class_attributes_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER rate_class_attributes_check AFTER INSERT OR DELETE OR UPDATE ON tariff_dev_v2.rate_class_attributes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_rate_class_attributes_check();


--
-- TOC entry 11776 (class 2620 OID 180043259)
-- Name: rates rates_attribute_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER rates_attribute_check AFTER INSERT OR UPDATE OF rate_class_id, attribute_collection_id ON tariff_dev_v2.rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_rates_attribute_check();


--
-- TOC entry 11777 (class 2620 OID 181673766)
-- Name: rates rates_block_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER rates_block_check AFTER INSERT OR UPDATE OF rate_class_id, block_from ON tariff_dev_v2.rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_rates_block_check();


--
-- TOC entry 11778 (class 2620 OID 180043615)
-- Name: rates rates_window_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER rates_window_check AFTER INSERT OR UPDATE OF tariff_id, rate_class_id, valid_from, valid_to ON tariff_dev_v2.rates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_rates_window_check();


--
-- TOC entry 11772 (class 2620 OID 180043617)
-- Name: tariff_rate_classes tariff_rate_classes_window_check; Type: TRIGGER; Schema: tariff_dev_v2; Owner: -
--

CREATE CONSTRAINT TRIGGER tariff_rate_classes_window_check AFTER INSERT OR DELETE OR UPDATE ON tariff_dev_v2.tariff_rate_classes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tariff_dev_v2.trg_tariff_rate_classes_window_check();


--
-- TOC entry 11747 (class 2606 OID 180042710)
-- Name: attribute_collection_values attribute_collection_values_attribute_collection_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_collection_values
    ADD CONSTRAINT attribute_collection_values_attribute_collection_id_fkey FOREIGN KEY (attribute_collection_id) REFERENCES tariff_dev_v2.attribute_collections(attribute_collection_id) ON DELETE CASCADE;


--
-- TOC entry 11748 (class 2606 OID 180042715)
-- Name: attribute_collection_values attribute_collection_values_attribute_id_attribute_value_i_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_collection_values
    ADD CONSTRAINT attribute_collection_values_attribute_id_attribute_value_i_fkey FOREIGN KEY (attribute_id, attribute_value_id) REFERENCES tariff_dev_v2.attribute_values(attribute_id, attribute_value_id);


--
-- TOC entry 11744 (class 2606 OID 180042666)
-- Name: attribute_values attribute_values_attribute_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.attribute_values
    ADD CONSTRAINT attribute_values_attribute_id_fkey FOREIGN KEY (attribute_id) REFERENCES tariff_dev_v2.attributes(attribute_id);


--
-- TOC entry 11770 (class 2606 OID 180053889)
-- Name: holiday_scheme_days holiday_scheme_days_holiday_date_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.holiday_scheme_days
    ADD CONSTRAINT holiday_scheme_days_holiday_date_fkey FOREIGN KEY (holiday_date) REFERENCES tariff_dev_v2.public_holidays(holiday_date);


--
-- TOC entry 11771 (class 2606 OID 180053884)
-- Name: holiday_scheme_days holiday_scheme_days_holiday_scheme_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.holiday_scheme_days
    ADD CONSTRAINT holiday_scheme_days_holiday_scheme_id_fkey FOREIGN KEY (holiday_scheme_id) REFERENCES tariff_dev_v2.holiday_schemes(holiday_scheme_id);


--
-- TOC entry 11745 (class 2606 OID 180042683)
-- Name: rate_class_attributes rate_class_attributes_attribute_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_attributes
    ADD CONSTRAINT rate_class_attributes_attribute_id_fkey FOREIGN KEY (attribute_id) REFERENCES tariff_dev_v2.attributes(attribute_id);


--
-- TOC entry 11746 (class 2606 OID 180042678)
-- Name: rate_class_attributes rate_class_attributes_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_attributes
    ADD CONSTRAINT rate_class_attributes_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11767 (class 2606 OID 180042964)
-- Name: rate_class_operation_implementation rate_class_operation_implementation_operation_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_operation_implementation
    ADD CONSTRAINT rate_class_operation_implementation_operation_id_fkey FOREIGN KEY (operation_id) REFERENCES tariff_dev_v2.rate_operations(operation_id);


--
-- TOC entry 11768 (class 2606 OID 180042959)
-- Name: rate_class_operation_implementation rate_class_operation_implementation_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_operation_implementation
    ADD CONSTRAINT rate_class_operation_implementation_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11769 (class 2606 OID 180042969)
-- Name: rate_class_operation_implementation rate_class_operation_implementation_signature_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_operation_implementation
    ADD CONSTRAINT rate_class_operation_implementation_signature_id_fkey FOREIGN KEY (signature_id) REFERENCES tariff_dev_v2.implementation_signatures(signature_id);


--
-- TOC entry 11749 (class 2606 OID 180042758)
-- Name: rate_class_tou_periods rate_class_tou_periods_period_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_tou_periods
    ADD CONSTRAINT rate_class_tou_periods_period_id_fkey FOREIGN KEY (period_id) REFERENCES tariff_dev_v2.tou_periods(period_id);


--
-- TOC entry 11750 (class 2606 OID 180042753)
-- Name: rate_class_tou_periods rate_class_tou_periods_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_tou_periods
    ADD CONSTRAINT rate_class_tou_periods_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11751 (class 2606 OID 180042772)
-- Name: rate_class_tou_seasons rate_class_tou_seasons_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_tou_seasons
    ADD CONSTRAINT rate_class_tou_seasons_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11752 (class 2606 OID 180042777)
-- Name: rate_class_tou_seasons rate_class_tou_seasons_season_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rate_class_tou_seasons
    ADD CONSTRAINT rate_class_tou_seasons_season_id_fkey FOREIGN KEY (season_id) REFERENCES tariff_dev_v2.tou_seasons(season_id);


--
-- TOC entry 11761 (class 2606 OID 180042909)
-- Name: rates rates_attribute_collection_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_attribute_collection_id_fkey FOREIGN KEY (attribute_collection_id) REFERENCES tariff_dev_v2.attribute_collections(attribute_collection_id);


--
-- TOC entry 11762 (class 2606 OID 180042904)
-- Name: rates rates_pattern_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_pattern_class_id_fkey FOREIGN KEY (pattern_class_id) REFERENCES tariff_dev_v2.tou_patterns(pattern_class_id);


--
-- TOC entry 11763 (class 2606 OID 180042919)
-- Name: rates rates_period_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_period_id_fkey FOREIGN KEY (period_id) REFERENCES tariff_dev_v2.tou_periods(period_id);


--
-- TOC entry 11764 (class 2606 OID 180042899)
-- Name: rates rates_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11765 (class 2606 OID 180042914)
-- Name: rates rates_season_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_season_id_fkey FOREIGN KEY (season_id) REFERENCES tariff_dev_v2.tou_seasons(season_id);


--
-- TOC entry 11766 (class 2606 OID 180042894)
-- Name: rates rates_tariff_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.rates
    ADD CONSTRAINT rates_tariff_id_fkey FOREIGN KEY (tariff_id) REFERENCES tariff_dev_v2.tariffs(tariff_id);


--
-- TOC entry 11742 (class 2606 OID 180042631)
-- Name: tariff_rate_classes tariff_rate_classes_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_rate_classes
    ADD CONSTRAINT tariff_rate_classes_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11743 (class 2606 OID 180042626)
-- Name: tariff_rate_classes tariff_rate_classes_tariff_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_rate_classes
    ADD CONSTRAINT tariff_rate_classes_tariff_id_fkey FOREIGN KEY (tariff_id) REFERENCES tariff_dev_v2.tariffs(tariff_id);


--
-- TOC entry 11756 (class 2606 OID 180053894)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_holiday_scheme_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_holiday_scheme_id_fkey FOREIGN KEY (holiday_scheme_id) REFERENCES tariff_dev_v2.holiday_schemes(holiday_scheme_id);


--
-- TOC entry 11757 (class 2606 OID 180042861)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_pattern_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_pattern_class_id_fkey FOREIGN KEY (pattern_class_id) REFERENCES tariff_dev_v2.tou_patterns(pattern_class_id);


--
-- TOC entry 11758 (class 2606 OID 180042866)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_pattern_detail_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_pattern_detail_id_fkey FOREIGN KEY (pattern_detail_id) REFERENCES tariff_dev_v2.tou_pattern_groups(pattern_detail_id);


--
-- TOC entry 11759 (class 2606 OID 180042856)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_rate_class_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_rate_class_id_fkey FOREIGN KEY (rate_class_id) REFERENCES tariff_dev_v2.rate_classes(rate_class_id);


--
-- TOC entry 11760 (class 2606 OID 180042851)
-- Name: tariff_tou_pattern_link tariff_tou_pattern_link_tariff_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariff_tou_pattern_link
    ADD CONSTRAINT tariff_tou_pattern_link_tariff_id_fkey FOREIGN KEY (tariff_id) REFERENCES tariff_dev_v2.tariffs(tariff_id);


--
-- TOC entry 11740 (class 2606 OID 180042591)
-- Name: tariffs tariffs_country_code_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariffs
    ADD CONSTRAINT tariffs_country_code_fkey FOREIGN KEY (country_code) REFERENCES tariff_dev_v2.countries(country_code);


--
-- TOC entry 11741 (class 2606 OID 180042596)
-- Name: tariffs tariffs_currency_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tariffs
    ADD CONSTRAINT tariffs_currency_fkey FOREIGN KEY (currency) REFERENCES tariff_dev_v2.currencies(currency_code);


--
-- TOC entry 11753 (class 2606 OID 180042819)
-- Name: tou_pattern_detail tou_pattern_detail_pattern_detail_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_pattern_detail
    ADD CONSTRAINT tou_pattern_detail_pattern_detail_id_fkey FOREIGN KEY (pattern_detail_id) REFERENCES tariff_dev_v2.tou_pattern_groups(pattern_detail_id);


--
-- TOC entry 11754 (class 2606 OID 180042829)
-- Name: tou_pattern_detail tou_pattern_detail_period_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_pattern_detail
    ADD CONSTRAINT tou_pattern_detail_period_id_fkey FOREIGN KEY (period_id) REFERENCES tariff_dev_v2.tou_periods(period_id);


--
-- TOC entry 11755 (class 2606 OID 180042824)
-- Name: tou_pattern_detail tou_pattern_detail_season_id_fkey; Type: FK CONSTRAINT; Schema: tariff_dev_v2; Owner: -
--

ALTER TABLE ONLY tariff_dev_v2.tou_pattern_detail
    ADD CONSTRAINT tou_pattern_detail_season_id_fkey FOREIGN KEY (season_id) REFERENCES tariff_dev_v2.tou_seasons(season_id);


-- Completed on 2026-11-26 08:41:32 EST

--
-- PostgreSQL database dump complete
--


