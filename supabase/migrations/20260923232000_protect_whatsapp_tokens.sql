revoke select on public.whatsapp_accounts from authenticated;

grant select (
  id,
  tenant_id,
  phone_number_id,
  business_account_id,
  display_phone_number,
  name,
  status,
  created_at,
  updated_at
)
on public.whatsapp_accounts to authenticated;
