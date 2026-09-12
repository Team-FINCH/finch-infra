BEGIN;

DO $$
DECLARE
    demo_user_id BIGINT;
    demo_account_id BIGINT;
    demo_payment_id BIGINT;
    deposit_ledger_id BIGINT;
    samsung_ledger_id BIGINT;
    hynix_ledger_id BIGINT;
    naver_ledger_id BIGINT;
BEGIN
    SELECT id INTO STRICT demo_user_id FROM users WHERE kakao_id = -1;
    SELECT id INTO STRICT demo_account_id FROM account WHERE user_id = demo_user_id FOR UPDATE;

    -- 고정 시연 계정의 사용자 활동과 자산을 같은 상태로 되돌린다.
    DELETE FROM inbox_read WHERE user_id = demo_user_id;
    DELETE FROM recent_viewed_stock WHERE user_id = demo_user_id;
    DELETE FROM recent_search_keyword WHERE user_id = demo_user_id;
    DELETE FROM watchlist_item WHERE user_id = demo_user_id;
    DELETE FROM withdrawal WHERE account_id = demo_account_id;
    DELETE FROM deposit WHERE account_id = demo_account_id;
    DELETE FROM payment WHERE account_id = demo_account_id;
    DELETE FROM trade WHERE account_id = demo_account_id;
    DELETE FROM holding WHERE account_id = demo_account_id;
    DELETE FROM ledger_entry WHERE account_id = demo_account_id;

    UPDATE users
       SET nickname = 'FINCH 시연 계정', updated_at = now()
     WHERE id = demo_user_id;

    UPDATE account
       SET cash_balance = 7400000,
           total_deposited_amount = 10000000,
           updated_at = now()
     WHERE id = demo_account_id;

    INSERT INTO ledger_entry(account_id, type, cash_delta, cash_balance_after, occurred_at, created_at)
    VALUES (demo_account_id, 'DEPOSIT', 10000000, 10000000, now() - interval '30 days', now() - interval '30 days')
    RETURNING id INTO deposit_ledger_id;

    INSERT INTO payment(account_id, payment_method, amount, status, payment_key, created_at, approved_at, completed_at, expires_at)
    VALUES (demo_account_id, 'TRANSFER', 10000000, 'DONE', 'demo_fixed_account_seed',
            now() - interval '30 days', now() - interval '30 days', now() - interval '30 days', now() - interval '30 days')
    RETURNING id INTO demo_payment_id;

    INSERT INTO deposit(ledger_entry_id, account_id, amount, payment_method, created_at, payment_id)
    VALUES (deposit_ledger_id, demo_account_id, 10000000, 'TRANSFER', now() - interval '30 days', demo_payment_id);

    INSERT INTO ledger_entry(account_id, type, cash_delta, cash_balance_after, occurred_at, created_at)
    VALUES (demo_account_id, 'BUY', -1400000, 8600000, now() - interval '21 days', now() - interval '21 days')
    RETURNING id INTO samsung_ledger_id;
    INSERT INTO trade(ledger_entry_id, account_id, stock_code, side, quantity, executed_price, executed_amount, executed_at)
    VALUES (samsung_ledger_id, demo_account_id, '005930', 'BUY', 20, 70000, 1400000, now() - interval '21 days');

    INSERT INTO ledger_entry(account_id, type, cash_delta, cash_balance_after, occurred_at, created_at)
    VALUES (demo_account_id, 'BUY', -900000, 7700000, now() - interval '14 days', now() - interval '14 days')
    RETURNING id INTO hynix_ledger_id;
    INSERT INTO trade(ledger_entry_id, account_id, stock_code, side, quantity, executed_price, executed_amount, executed_at)
    VALUES (hynix_ledger_id, demo_account_id, '000660', 'BUY', 5, 180000, 900000, now() - interval '14 days');

    INSERT INTO ledger_entry(account_id, type, cash_delta, cash_balance_after, occurred_at, created_at)
    VALUES (demo_account_id, 'BUY', -300000, 7400000, now() - interval '7 days', now() - interval '7 days')
    RETURNING id INTO naver_ledger_id;
    INSERT INTO trade(ledger_entry_id, account_id, stock_code, side, quantity, executed_price, executed_amount, executed_at)
    VALUES (naver_ledger_id, demo_account_id, '035420', 'BUY', 2, 150000, 300000, now() - interval '7 days');

    INSERT INTO holding(account_id, stock_code, quantity, avg_buy_price, updated_at) VALUES
        (demo_account_id, '005930', 20, 70000, now() - interval '21 days'),
        (demo_account_id, '000660', 5, 180000, now() - interval '14 days'),
        (demo_account_id, '035420', 2, 150000, now() - interval '7 days');

    INSERT INTO watchlist_item(user_id, stock_code, created_at) VALUES
        (demo_user_id, '005930', now() - interval '28 days'),
        (demo_user_id, '000660', now() - interval '20 days'),
        (demo_user_id, '035420', now() - interval '13 days'),
        (demo_user_id, '035720', now() - interval '5 days'),
        (demo_user_id, '005380', now() - interval '2 days');
END $$;

COMMIT;
