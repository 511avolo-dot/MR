-- P0-1w regression: future public functions fail closed until explicitly granted.
DO $test$
DECLARE
  v_role name;
  v_grantee oid;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['PUBLIC','anon','authenticated','service_role']::name[] LOOP
    v_grantee := CASE WHEN v_role = 'PUBLIC' THEN 0 ELSE to_regrole(v_role)::oid END;

    IF EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      CROSS JOIN LATERAL aclexplode(d.defaclacl) a
      WHERE pg_get_userbyid(d.defaclrole) = 'postgres'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'f'
        AND a.grantee = v_grantee
        AND a.privilege_type = 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'DA1 fail: future postgres-owned public functions grant EXECUTE to %', v_role;
    END IF;

    RAISE NOTICE 'PASS DA1 future functions do not auto-grant EXECUTE to %', v_role;
  END LOOP;
END $test$;
