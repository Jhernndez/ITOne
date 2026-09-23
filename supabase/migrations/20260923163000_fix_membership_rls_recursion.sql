drop policy if exists "members can read memberships in their tenants"
on public.tenant_memberships;

create policy "users can read their own memberships"
on public.tenant_memberships for select to authenticated
using (user_id = (select auth.uid()));
