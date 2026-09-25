-- API credentials must never be readable by tenant members.
revoke select (auth_config) on public.tenant_api_integrations from authenticated;
revoke insert (auth_config), update (auth_config) on public.tenant_api_integrations from authenticated;
