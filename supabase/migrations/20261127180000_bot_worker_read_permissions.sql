grant select (tenant_id, flow_id, version, graph)
  on public.automation_flow_versions to service_role;

grant select (id, tenant_id, integration_id, path, http_method, enabled,
  enabled_for_automation, allow_automation_writes)
  on public.tenant_api_resources to service_role;

grant select (id, tenant_id, base_url, auth_type, auth_config, enabled)
  on public.tenant_api_integrations to service_role;
