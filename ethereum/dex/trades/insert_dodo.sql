CREATE OR REPLACE FUNCTION dex.insert_dodo(start_ts timestamptz, end_ts timestamptz=now(), start_block numeric=0, end_block numeric=9e18) RETURNS integer
LANGUAGE plpgsql AS $function$
DECLARE r integer;
BEGIN
WITH rows AS (
    INSERT INTO dex.trades (
        block_time,
        token_a_symbol,
        token_b_symbol,
        token_a_amount,
        token_b_amount,
        project,
        version,
        category,
        trader_a,
        trader_b,
        token_a_amount_raw,
        token_b_amount_raw,
        usd_amount,
        token_a_address,
        token_b_address,
        exchange_contract_address,
        tx_hash,
        tx_from,
        tx_to,
        trace_address,
        evt_index,
        trade_id
    )
    SELECT
        dexs.block_time,
        erc20a.symbol AS token_a_symbol,
        erc20b.symbol AS token_b_symbol,
        token_a_amount_raw / 10 ^ erc20a.decimals AS token_a_amount,
        token_b_amount_raw / 10 ^ erc20b.decimals AS token_b_amount,
        project,
        version,
        category,
        coalesce(trader_a, tx."from") as trader_a, -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
        trader_b,
        token_a_amount_raw,
        token_b_amount_raw,
        coalesce(
            usd_amount,
            token_a_amount_raw / 10 ^ erc20a.decimals * pa.price,
            token_b_amount_raw / 10 ^ erc20b.decimals * pb.price
        ) as usd_amount,
        token_a_address,
        token_b_address,
        exchange_contract_address,
        tx_hash,
        tx."from" as tx_from,
        tx."to" as tx_to,
        trace_address,
        evt_index,
        row_number() OVER (PARTITION BY tx_hash, evt_index, trace_address) AS trade_id
    FROM (

        -- dodo v1 sell
        SELECT
            s.evt_block_time AS block_time,
            'dodo' AS project,
            '1' AS version,
            'DEX' AS category,
            s.seller AS trader_a,
            NULL::bytea AS trader_b,
            s."payBase" token_a_amount_raw,
            s."receiveQuote" token_b_amount_raw,
            NULL::numeric AS usd_amount,
            m.base_token_address AS token_a_address,
            m.quote_token_address AS token_b_address,
            s.contract_address exchange_contract_address,
            s.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            s.evt_index
        FROM
            dodo."DODO_evt_SellBaseToken" s
        LEFT JOIN dodo."view_markets" m on s.contract_address = m.market_contract_address
        WHERE s.seller <> '\xa356867fdcea8e71aeaf87805808803806231fdc'

        UNION ALL

        -- dodo v1 buy
        SELECT
            b.evt_block_time AS block_time,
            'dodo' AS project,
            '1' AS version,
            'DEX' AS category,
            b.buyer AS trader_a,
            NULL::bytea AS trader_b,
            b."receiveBase" token_a_amount_raw,
            b."payQuote" token_b_amount_raw,
            NULL::numeric AS usd_amount,
            m.base_token_address AS token_a_address,
            m.quote_token_address AS token_b_address,
            b.contract_address exchange_contract_address,
            b.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            b.evt_index
        FROM
            dodo."DODO_evt_BuyBaseToken" b
        LEFT JOIN dodo."view_markets" m on b.contract_address = m.market_contract_address
        WHERE b.buyer <> '\xa356867fdcea8e71aeaf87805808803806231fdc'

        UNION ALL

        -- dodov1 proxy01
        SELECT
            evt_block_time AS block_time,
            'dodo' AS project,
            '1' AS version,
            'DEX' AS category,
            sender AS trader_a,
            NULL::bytea AS trader_b,
            "fromAmount" token_a_amount_raw,
            "returnAmount" token_b_amount_raw,
            NULL::numeric AS usd_amount,
            "fromToken" AS token_a_address,
            "toToken" AS token_b_address,
            contract_address exchange_contract_address,
            evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            evt_index
        FROM
            dodo."DODOV1Proxy01_evt_OrderHistory"

        UNION ALL

        -- dodov1 proxy04
        SELECT
            evt_block_time AS block_time,
            'dodo' AS project,
            '1' AS version,
            'DEX' AS category,
            sender AS trader_a,
            NULL::bytea AS trader_b,
            "fromAmount" token_a_amount_raw,
            "returnAmount" token_b_amount_raw,
            NULL::numeric AS usd_amount,
            "fromToken" AS token_a_address,
            "toToken" AS token_b_address,
            contract_address exchange_contract_address,
            evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            evt_index
        FROM
            dodo."DODOV1Proxy04_evt_OrderHistory"

        UNION ALL

        -- dodov2 proxy02
        SELECT
            evt_block_time AS block_time,
            'dodo' AS project,
            '2' AS version,
            'DEX' AS category,
            sender AS trader_a,
            NULL::bytea AS trader_b,
            "fromAmount" token_a_amount_raw,
            "returnAmount" token_b_amount_raw,
            NULL::numeric AS usd_amount,
            "fromToken" AS token_a_address,
            "toToken" AS token_b_address,
            contract_address exchange_contract_address,
            evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            evt_index
        FROM
            dodo."DODOV2Proxy02_evt_OrderHistory"

        UNION ALL

        -- dodov2 dvm
        SELECT
            evt_block_time AS block_time,
            'dodo' AS project,
            '2' AS version,
            'DEX' AS category,
            trader AS trader_a,
            receiver AS trader_b,
            "fromAmount" token_a_amount_raw,
            "toAmount" token_b_amount_raw,
            NULL::numeric AS usd_amount,
            "fromToken" AS token_a_address,
            "toToken" AS token_b_address,
            contract_address exchange_contract_address,
            evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            evt_index
        FROM
            dodo."DVM_evt_DODOSwap"
        WHERE trader <> '\xa356867fdcea8e71aeaf87805808803806231fdc'

        UNION ALL

        -- dodov2 dpp
        SELECT
            evt_block_time AS block_time,
            'dodo' AS project,
            '2' AS version,
            'DEX' AS category,
            trader AS trader_a,
            receiver AS trader_b,
            "fromAmount" AS token_a_amount_raw,
            "toAmount" AS token_b_amount_raw,
            NULL::numeric AS usd_amount,
            "fromToken" AS token_a_address,
            "toToken" AS token_b_address,
            contract_address AS exchange_contract_address,
            evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            evt_index
        FROM
            dodo."DPP_evt_DODOSwap"
        WHERE trader <> '\xa356867fdcea8e71aeaf87805808803806231fdc'
    ) dexs
    INNER JOIN ethereum.transactions tx
        ON dexs.tx_hash = tx.hash
        AND tx.block_time >= start_ts
        AND tx.block_time < end_ts
        AND tx.block_number >= start_block
        AND tx.block_number < end_block
    LEFT JOIN erc20.tokens erc20a ON erc20a.contract_address = dexs.token_a_address
    LEFT JOIN erc20.tokens erc20b ON erc20b.contract_address = dexs.token_b_address
    LEFT JOIN prices.usd pa ON pa.minute = date_trunc('minute', dexs.block_time)
        AND pa.contract_address = dexs.token_a_address
        AND pa.minute >= start_ts
        AND pa.minute < end_ts
    LEFT JOIN prices.usd pb ON pb.minute = date_trunc('minute', dexs.block_time)
        AND pb.contract_address = dexs.token_b_address
        AND pb.minute >= start_ts
        AND pb.minute < end_ts
    WHERE dexs.block_time >= start_ts
    AND dexs.block_time < end_ts

    ON CONFLICT DO NOTHING
    RETURNING 1
)
SELECT count(*) INTO r from rows;
RETURN r;
END
$function$;

-- fill 2020
SELECT dex.insert_dodo(
    '2020-01-01',
    '2021-01-01',
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2020-01-01'),
    (SELECT max(number) FROM ethereum.blocks WHERE time <= '2021-01-01')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2020-01-01'
    AND block_time <= '2021-01-01'
    AND project = 'dodo'
);

-- fill 2021
SELECT dex.insert_dodo(
    '2021-01-01',
    now(),
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2021-01-01'),
    (SELECT max(number) FROM ethereum.blocks)
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2021-01-01'
    AND block_time <= now()
    AND project = 'dodo'
);

INSERT INTO cron.job (schedule, command)
VALUES ('*/10 * * * *', $$
    SELECT dex.insert_dodo(
        (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='dodo'),
        (SELECT now()),
        (SELECT max(number) FROM ethereum.blocks WHERE time < (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='dodo')),
        (SELECT MAX(number) FROM ethereum.blocks));
$$)
ON CONFLICT (command) DO UPDATE SET schedule=EXCLUDED.schedule;