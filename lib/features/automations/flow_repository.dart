import 'package:supabase_flutter/supabase_flutter.dart';

import 'flow_graph.dart';

class SavedFlow {
  SavedFlow(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      revision = json['revision'] as int,
      publishedVersion = json['published_version'] as int?,
      graph = FlowGraph.fromJson(
        Map<String, dynamic>.from(json['draft'] as Map),
      );
  final String id;
  final String name;
  final int revision;
  final int? publishedVersion;
  final FlowGraph graph;
}

class FlowVersion {
  FlowVersion(Map<String, dynamic> json)
    : version = json['version'] as int,
      name = json['name'] as String,
      graph = FlowGraph.fromJson(
        Map<String, dynamic>.from(json['graph'] as Map),
      );
  final int version;
  final String name;
  final FlowGraph graph;
}

class FlowRepository {
  FlowRepository(this.client);
  final SupabaseClient client;
  Future<List<SavedFlow>> list(String tenantId) async {
    final rows = await client
        .from('automation_flows')
        .select()
        .eq('tenant_id', tenantId)
        .order('updated_at', ascending: false);
    return rows.map(SavedFlow.new).toList();
  }

  Future<SavedFlow> save(
    String tenantId,
    SavedFlow? previous,
    String name,
    FlowGraph graph,
  ) async {
    final result = await client.rpc(
      'save_automation_flow',
      params: {
        'p_tenant_id': tenantId,
        'p_flow_id': previous?.id,
        'p_name': name,
        'p_graph': graph.toJson(),
        'p_expected_revision': previous?.revision,
      },
    );
    return SavedFlow(Map<String, dynamic>.from(result as Map));
  }

  Future<SavedFlow> publish(String tenantId, SavedFlow flow) async {
    final result = await client.rpc(
      'publish_automation_flow',
      params: {
        'p_tenant_id': tenantId,
        'p_flow_id': flow.id,
        'p_expected_revision': flow.revision,
      },
    );
    return SavedFlow(Map<String, dynamic>.from(result as Map));
  }

  Future<List<FlowVersion>> versions(String tenantId, String flowId) async {
    final rows = await client
        .from('automation_flow_versions')
        .select()
        .eq('tenant_id', tenantId)
        .eq('flow_id', flowId)
        .order('version', ascending: false);
    return rows.map(FlowVersion.new).toList();
  }
}
