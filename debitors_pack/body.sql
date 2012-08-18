create or replace
PACKAGE BODY DEBITORS_PACK AS

-- Utils

FUNCTION normal_amount(p_operkey NUMBER, p_gel NUMBER) RETURN NUMBER
IS
BEGIN
  IF p_operkey IN (12,15,16,35,49,59,150)
  THEN
    RETURN - p_gel;
  ELSE
    RETURN + p_gel;
  END IF;
END;

FUNCTION find_schedule(p_row bs.item%ROWTYPE)
RETURN NUMBER
IS
  l_schedule NUMBER;
BEGIN
  IF p_row.schedkey IS NOT NULL
  THEN
    l_schedule := p_row.schedkey;
  ELSIF p_row.billoperkey = 38
  THEN
    BEGIN
      SELECT schedkey INTO l_schedule FROM bs.route_store
      WHERE
        custkey = p_row.custkey AND
        new_readdate = p_row.itemdate AND
        ROWNUM = 1;
    EXCEPTION WHEN no_data_found
    THEN
      l_schedule := NULL;
    END;
    IF l_schedule IS NULL
    THEN
      BEGIN
        SELECT schedkey INTO l_schedule FROM BS.item
        WHERE
          custkey = p_row.custkey AND
          itemdate = p_row.itemdate AND
          schedkey IS NOT NULL AND
          ROWNUM = 1;
      EXCEPTION WHEN no_data_found
      THEN
        l_schedule := NULL;
      END;
    END IF;
    NULL;
  END IF;
  RETURN l_schedule;
END;

FUNCTION missholidays(p_start IN DATE, p_workdays IN NUMBER) RETURN DATE IS
  l_cnt NUMBER := 0;
  l_i   NUMBER := 0;
BEGIN
  WHILE (l_cnt < p_workdays) LOOP
    l_i  := l_i  + 1;
    IF TRIM(to_char(p_start + l_i, 'DAY')) NOT IN ('SATURDAY', 'SUNDAY')
    THEN
      l_cnt := l_cnt + 1;
    END IF;
  END LOOP;
  RETURN p_start + l_i;
END;

----------------------------------------------------------------------------------------------------
-- STATUS management (used in DEBITORS management)
----------------------------------------------------------------------------------------------------

FUNCTION start_customer_status(p_statusid NUMBER, p_customer NUMBER, p_date DATE, p_balance NUMBER := 0) RETURN BOOLEAN
IS
  l_key NUMBER;
BEGIN
  BEGIN
    SELECT customers_status_id INTO l_key FROM BS.zcutomers_status
    WHERE status_activity = 0 AND custkey = p_customer AND statusid = p_statusid AND rownum = 1;
    RETURN FALSE;
  EXCEPTION WHEN no_data_found
  THEN
    INSERT INTO BS.zcutomers_status (
      custkey, statusid, startdate, enddate, groupid, insectorid, operkey, status_activity,
      start_balance, end_balance
    ) VALUES (
      p_customer, p_statusid, p_date, null, 1, 1, 1, 0,
      p_balance, 0
    );
    RETURN TRUE;
  END;
END;

PROCEDURE end_customer_status(p_statusid NUMBER, p_customer NUMBER, p_date DATE, p_balance NUMBER := 0)
IS
  l_key NUMBER;
  l_start DATE;
BEGIN
  BEGIN
    SELECT customers_status_id, startdate INTO l_key, l_start FROM BS.zcutomers_status
    WHERE status_activity = 0 AND custkey = p_customer AND statusid = p_statusid AND rownum = 1;
    IF TRUNC(p_date) = TRUNC(l_start)
    THEN
      DELETE BS.zcutomers_status
      WHERE customers_status_id = l_key;
    ELSE
      UPDATE BS.zcutomers_status SET
        enddate = p_date, status_activity = 1, end_balance = p_balance
      WHERE customers_status_id = l_key;
    END IF;
  EXCEPTION WHEN no_data_found
  THEN
    -- nothing todo here!!
    NULL;
  END;
END;

PROCEDURE append_task(p_statusid NUMBER, p_custkey NUMBER) IS
  l_text VARCHAR(100);
  l_inspector NUMBER;
BEGIN
  IF APPEND_TASKS
  THEN
    SELECT description INTO l_text FROM bs.zstatus_list WHERE statusid = p_statusid;
    SELECT perskey INTO l_inspector FROM BS.zinspe_customer WHERE custkey = p_custkey;
    INSERT INTO BS.znote (custkey, workdate, enterdate, note, inspectkey, perskey, is_executed, notetype)
    VALUES (p_custkey, TRUNC(sysdate), sysdate, l_text, l_inspector, 1, 0, 0);
  END IF;
EXCEPTION WHEN no_data_found
THEN
  NULL;
END;

PROCEDURE check_for_prev_balance(p_item bs.item%ROWTYPE, p_debitorkey NUMBER)
IS
  l_curr_balance NUMBER;
  l_balance NUMBER;
  l_resp    BOOLEAN;
BEGIN
  SELECT cur_charge + vaucher + subsidies + portion + all_payment
  INTO l_curr_balance
  FROM bs.zdebitors
  WHERE debitorsid = p_debitorkey;

  IF l_curr_balance >= 0
  THEN
    l_balance := p_item.balance + normal_amount(p_item.billoperkey, p_item.amount) - l_curr_balance;
  ELSE
    l_balance := p_item.balance + normal_amount(p_item.billoperkey, p_item.amount);
  END IF;

  -- 8: balance >= 50
  -- 15: balance >= 5000

  IF l_balance >= 5000
  THEN
    end_customer_status(STAT_BALANCE_GE_50, p_item.custkey, TRUNC(p_item.itemdate), l_balance);
    l_resp := start_customer_status(STAT_BALANCE_GE_5000, p_item.custkey, TRUNC(p_item.itemdate), l_balance);
    IF l_resp
    THEN
      append_task(STAT_BALANCE_GE_5000, p_item.custkey);
    END IF;
  ELSIF l_balance >= 50
  THEN
    l_resp := start_customer_status(STAT_BALANCE_GE_50, p_item.custkey, TRUNC(p_item.itemdate), l_balance);
    end_customer_status(STAT_BALANCE_GE_5000, p_item.custkey, TRUNC(p_item.itemdate), l_balance);
    IF l_resp
    THEN
      append_task(STAT_BALANCE_GE_50, p_item.custkey);
    END IF;
  ELSE
    end_customer_status(STAT_BALANCE_GE_50, p_item.custkey, TRUNC(p_item.itemdate), l_balance);
    end_customer_status(STAT_BALANCE_GE_5000, p_item.custkey, TRUNC(p_item.itemdate), l_balance);
  END IF;
END;

PROCEDURE check_debt_agrmnt_violation(p_item bs.item%ROWTYPE, p_debitorkey NUMBER)
IS
  l_portion NUMBER;
  l_status NUMBER;
  l_cut_date DATE;
  l_resp BOOLEAN;
BEGIN

  -- TODO: gaugebaria saerTod!! -- statusi araa gamoyenebuli

  SELECT portion, pay_status, discon_date INTO l_portion, l_status, l_cut_date
  FROM BS.zdebitors
  WHERE debitorsid = p_debitorkey;
  IF NVL(l_portion, 0) > 0 AND l_cut_date IS NOT NULL AND l_cut_date > p_item.itemdate 
  THEN
    l_resp := start_customer_status(STAT_SCHEDULE_VIOLATION, p_item.custkey, p_item.itemdate);
    IF l_resp
    THEN
      append_task(STAT_SCHEDULE_VIOLATION, p_item.custkey);
    END IF;
  ELSE
    end_customer_status(STAT_SCHEDULE_VIOLATION, p_item.custkey, p_item.itemdate);
  END IF;
END;

PROCEDURE check_for_3_late_payments(p_customer NUMBER, p_date DATE)
IS
  l_last_debitorsid NUMBER;
  l_count NUMBER;
  l_resp BOOLEAN;
BEGIN

  -- last debitorsid (it should not be included!)
  BEGIN
    SELECT debitorsid INTO l_last_debitorsid FROM (
      SELECT debitorsid FROM bs.zdebitors WHERE custkey = p_customer
      ORDER BY debitorsid DESC
    ) WHERE ROWNUM = 1;
  EXCEPTION WHEN no_data_found
  THEN
    l_last_debitorsid := -1;
  END;

  -- Part A: count late payments

  SELECT COUNT(debitorsid) INTO l_count FROM (
    SELECT * FROM (
      SELECT * FROM bs.zdebitors
      WHERE custkey = p_customer AND debitorsid != l_last_debitorsid
      ORDER BY debitorsid DESC
    ) WHERE ROWNUM <= 12
  ) WHERE pay_status IN (-1, 0);

  IF NVL(l_count, 0) >= 3
  THEN
    l_resp := start_customer_status(STAT_PAY_VIOLATION, p_customer, p_date);
  ELSE
    end_customer_status(STAT_PAY_VIOLATION, p_customer, p_date);
  END IF;

END;

PROCEDURE check_meijare(p_customer NUMBER, p_date DATE)
IS
  l_custkey NUMBER;
  l_resp BOOLEAN;
BEGIN
  SELECT custkey INTO l_custkey
  FROM BS.act_customer_cust_meijare
  WHERE custkey = p_customer;
  l_resp := start_customer_status(2, p_customer, p_date);
EXCEPTION WHEN no_data_found
THEN
  end_customer_status(2, p_customer, p_date);
END;

PROCEDURE check_oldness(p_customer NUMBER, p_date DATE)
IS
  l_days NUMBER;
  l_resp BOOLEAN;
  l_currstat NUMBER;
BEGIN
  SELECT days INTO l_days
  FROM BS.cust_balances
  WHERE report_date = TRUNC(p_date) AND custkey = p_customer;
  IF l_days > LIMIT_OLDNESS
  THEN
    l_resp := start_customer_status(STAT_DEBT_TOO_OLD, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_1M, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_2M, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_3M, p_customer, TRUNC(p_date));
    l_currstat := STAT_DEBT_TOO_OLD;
  ELSIF l_days > LIMIT_OLDNESS - 30
  THEN
    end_customer_status(STAT_DEBT_TOO_OLD, p_customer, TRUNC(p_date));
    l_resp := start_customer_status(STAT_DEBT_OLDNESS_1M, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_2M, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_3M, p_customer, TRUNC(p_date));
    l_currstat := STAT_DEBT_OLDNESS_1M;
  ELSIF l_days > LIMIT_OLDNESS - 60
  THEN
    end_customer_status(STAT_DEBT_TOO_OLD, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_1M, p_customer, TRUNC(p_date));
    l_resp := start_customer_status(STAT_DEBT_OLDNESS_2M, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_3M, p_customer, TRUNC(p_date));
    l_currstat := STAT_DEBT_OLDNESS_2M;
  ELSIF l_days > LIMIT_OLDNESS - 60
  THEN
    end_customer_status(STAT_DEBT_TOO_OLD, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_1M, p_customer, TRUNC(p_date));
    end_customer_status(STAT_DEBT_OLDNESS_2M, p_customer, TRUNC(p_date));
    l_resp := start_customer_status(STAT_DEBT_OLDNESS_3M, p_customer, TRUNC(p_date));
    l_currstat := STAT_DEBT_OLDNESS_3M;
  END IF;
  IF l_currstat IS NOT NULL AND l_resp
  THEN
    append_task(l_currstat, p_customer);
  END IF;
EXCEPTION WHEN no_data_found
THEN
  NULL;
END;

PROCEDURE check_large_consumer(p_item bs.item%ROWTYPE, p_debitorkey NUMBER)
IS
  l_charge NUMBER;
  l_resp BOOLEAN;
BEGIN
  SELECT cur_charge INTO l_charge FROM bs.zdebitors
  WHERE debitorsid = p_debitorkey;
  IF l_charge >= 4800
  THEN
    l_resp := start_customer_status(STAT_LARGE_CONSUMER, p_item.custkey, TRUNC(p_item.itemdate));
    IF l_resp
    THEN
      append_task(STAT_LARGE_CONSUMER, p_item.custkey);
    END IF;
  ELSE
    end_customer_status(STAT_LARGE_CONSUMER, p_item.custkey, TRUNC(p_item.itemdate));
  END IF;
END;

----------------------------------------------------------------------------------------------------
-- DEBITOR management
----------------------------------------------------------------------------------------------------

FUNCTION get_customer_bonus_period(p_custkey NUMBER) RETURN NUMBER
IS
  l_custcatkey NUMBER;
  l_regionkey NUMBER;
  l_days NUMBER;
BEGIN
  BEGIN
    SELECT cust.custcatkey, adrs.regionkey
    INTO l_custcatkey, l_regionkey
    FROM bs.customer cust
    INNER JOIN bs.address adrs ON cust.premisekey = adrs.premisekey
    WHERE custkey = p_custkey;
    SELECT limitvalue INTO l_days
    FROM BS.personal_config_defaults
    WHERE
      limittype = 13 AND
      regionkey = l_regionkey AND
      custcatkey = l_custcatkey AND
      ROWNUM = 1;
    RETURN l_days;
  EXCEPTION WHEN no_data_found
  THEN
    RETURN 8;
  END;
END;

/**
 * Returns current ZDEBITORS row or creates one.
 */
FUNCTION get_zdebitor_row(p_item bs.item%ROWTYPE, p_schedule NUMBER)
RETURN NUMBER
IS
  l_debitorkey NUMBER;
BEGIN
  BEGIN
    IF p_schedule IS NOT NULL
    THEN
      SELECT debitorsid INTO l_debitorkey FROM (
        SELECT debitorsid FROM bs.zdebitors
        WHERE custkey = p_item.custkey AND schedkey = p_schedule
      ORDER BY debitorsid DESC) WHERE ROWNUM = 1;
    ELSE
      SELECT debitorsid INTO l_debitorkey FROM (
        SELECT debitorsid
        FROM bs.zdebitors WHERE custkey = p_item.custkey
        ORDER BY debitorsid DESC
      ) WHERE ROWNUM = 1;
    END IF;
  EXCEPTION WHEN no_data_found
  THEN
    INSERT INTO bs.zdebitors (
      custkey, enterdate, operdate, schedkey,
      cur_charge, all_payment, paydate, vaucher, vauchdate, subsidies, portion, kwh,
      prev_balance, pay_status, discon_date, last_paydate
    ) VALUES (
      p_item.custkey, SYSDATE, TRUNC(p_item.itemdate), p_schedule,
      0, 0, null, 0, null, 0, 0, 0,
      null, -1, null, null
    ) RETURNING debitorsid INTO l_debitorkey;
  END;
  RETURN l_debitorkey;
END;

PROCEDURE update_paystatus(p_item bs.item%ROWTYPE, p_debitorkey NUMBER)
IS
  l_balance     NUMBER;
  l_others      NUMBER;
  l_payment     NUMBER;
  l_paystatus   NUMBER;
  l_lastpaydate DATE;
  l_discondate  DATE;
  l_new_paystatus NUMBER;
BEGIN
  SELECT
    pay_status, all_payment, (cur_charge + vaucher + subsidies + portion),
    last_paydate, discon_date
  INTO
    l_paystatus, l_payment, l_others,
    l_lastpaydate, l_discondate
  FROM bs.zdebitors
  WHERE debitorsid = p_debitorkey;
  IF l_paystatus = -1
  THEN
    l_balance := p_item.balance + normal_amount(p_item.billoperkey, p_item.amount);
    IF l_balance < 0.01 OR (l_others + l_payment) < 0.01
    THEN
      IF l_discondate IS NOT NULL AND NVL(l_lastpaydate, p_item.itemdate) > l_discondate
      THEN
        l_new_paystatus := 0;
      ELSE
        l_new_paystatus := 1;
      END IF;
    END IF;
    IF l_new_paystatus IS NOT NULL
    THEN
      UPDATE bs.zdebitors SET
        pay_status = l_new_paystatus,
        paydate = l_lastpaydate
      WHERE debitorsid = p_debitorkey;
    END IF;
  END IF;
END;

PROCEDURE process_zdebitor_row(p_item bs.item%ROWTYPE) IS
  l_debitorkey NUMBER;
  l_opertype NUMBER;
  l_schedule NUMBER := find_schedule(p_item);
  l_amount NUMBER := normal_amount(p_item.billoperkey, p_item.amount);
  l_cut_date DATE;
  l_update_paystatus BOOLEAN := TRUE;
BEGIN
  -- getting operation type
  SELECT debitor_category INTO l_opertype
  FROM billoper_balance_categ
  WHERE billoperkey = p_item.billoperkey;

  -- getting debitor's row
  l_debitorkey := get_zdebitor_row(p_item, l_schedule);

  -- CHARGE
  IF l_opertype = TYPE_CHARGE
  THEN
    IF l_schedule IS NOT NULL
    THEN
      IF MISSHOLIDAYS_FROM_SYSDATE
      THEN
        l_cut_date := missholidays(TRUNC(sysdate), get_customer_bonus_period(p_item.custkey) + 1);
      ELSE
        l_cut_date := missholidays(TRUNC(p_item.enterdate), get_customer_bonus_period(p_item.custkey) + 1);
      END IF;
      UPDATE bs.zdebitors SET
        cur_charge = cur_charge + l_amount,
        kwh = kwh + p_item.kwt,
        discon_date = TRUNC(l_cut_date),
        last_itemkey = p_item.itemkey
      WHERE debitorsid = l_debitorkey;
    ELSE
      UPDATE bs.zdebitors SET
        cur_charge = cur_charge + l_amount,
        kwh = kwh + p_item.kwt,
        last_itemkey = p_item.itemkey
      WHERE debitorsid = l_debitorkey;
    END IF;
  -- PAYMNET
  ELSIF l_opertype = TYPE_PAYMNET
  THEN
    UPDATE bs.zdebitors SET
      all_payment = all_payment + l_amount,
      last_paydate = TRUNC(p_item.itemdate),
      last_itemkey = p_item.itemkey
    WHERE debitorsid = l_debitorkey;
  -- VOUCHER
  ELSIF l_opertype = TYPE_VOUCHER
  THEN
    UPDATE bs.zdebitors SET
      vaucher = vaucher + l_amount,
      vauchdate = TRUNC(p_item.itemdate),
      last_itemkey = p_item.itemkey
    WHERE debitorsid = l_debitorkey;
  -- SUBSIDY
  ELSIF l_opertype = TYPE_SUBSIDY
  THEN
    UPDATE bs.zdebitors SET
      subsidies = subsidies + l_amount,
      subsdate = TRUNC(p_item.itemdate),
      last_itemkey = p_item.itemkey
    WHERE debitorsid = l_debitorkey;
  -- DEBT AGREEMENT
  ELSIF l_opertype = TYPE_PORTION
  THEN
    UPDATE bs.zdebitors SET
      portion = portion + l_amount,
      last_itemkey = p_item.itemkey
    WHERE debitorsid = l_debitorkey;
  ELSE
    l_update_paystatus := FALSE;
  END IF;

  -- update paystatus
  IF l_update_paystatus
  THEN
    update_paystatus(p_item, l_debitorkey);
    check_for_prev_balance(p_item, l_debitorkey);
    check_debt_agrmnt_violation(p_item, l_debitorkey);
    check_large_consumer(p_item, l_debitorkey);
  END IF;

END;

PROCEDURE fill_zdebitors
IS
  l_itemkey NUMBER;
  l_now DATE := TRUNC(SYSDATE);
  l_from DATE := l_now - (365 + 60);
BEGIN
  FOR cust IN (SELECT * FROM bs.customer /*WHERE custkey = 148545*/)
  LOOP
    BEGIN
      BEGIN
        SELECT last_itemkey INTO l_itemkey FROM (
          SELECT last_itemkey FROM bs.zdebitors
          WHERE custkey = cust.custkey
          ORDER BY debitorsid DESC
        ) WHERE ROWNUM = 1;
        l_itemkey := l_itemkey + 1;
      EXCEPTION WHEN no_data_found
      THEN
        SELECT itemkey INTO l_itemkey FROM (
          SELECT * FROM bs.item
          WHERE custkey = cust.custkey
            AND itemdate >= l_from
            AND schedkey IS NOT NULL
          ORDER BY itemkey ASC
        ) WHERE ROWNUM = 1;
      END;

      FOR item IN (SELECT * FROM bs.item
        WHERE custkey = cust.custkey AND itemkey >= l_itemkey ORDER BY itemkey ASC)
      LOOP
        process_zdebitor_row(item);
      END LOOP;
      check_for_3_late_payments(cust.custkey, l_now);
      check_meijare(cust.custkey, l_now);
      check_oldness(cust.custkey, l_now);
      COMMIT;
    EXCEPTION WHEN no_data_found
    THEN
      NULL;
    END;
  END LOOP;
END;

END DEBITORS_PACK;