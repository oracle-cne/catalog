{{/* oci-config contains oci specific configs that is going to be used as a secret */}}
{{- define "oci-config" }}
auth:
{{ if not .Values.oci.useinstanceprincipals }}
  region: {{ .Values.oci.region }}
  tenancy: {{ .Values.oci.tenancy }}
  user: {{ .Values.oci.user }}
  key: |
{{ .Values.oci.privatekey | nindent 4 }}
  # Omit if there is not a password for the key
  passphrase: {{ default "" .Values.oci.passphrase }}
  fingerprint: {{ .Values.oci.fingerprint }}
{{ end }}
# Omit all of the above options then set useInstancePrincipals to true if you
# want to use Instance Principals API access
# (https://docs.us-phoenix-1.oraclecloud.com/Content/Identity/Tasks/callingservicesfrominstances.htm).
# Ensure you have setup the following OCI policies and your kubernetes nodes are running within them
# allow dynamic-group [your dynamic group name] to read instance-family in compartment [your compartment name]
# allow dynamic-group [your dynamic group name] to use virtual-network-family in compartment [your compartment name]
# allow dynamic-group [your dynamic group name] to manage load-balancers in compartment [your compartment name]
useInstancePrincipals: {{ .Values.oci.useinstanceprincipals }}

# compartment configures Compartment within which the cluster resides.
compartment: {{ .Values.oci.compartment }}

# vcn configures the Virtual Cloud Network (VCN) within which the cluster resides.
vcn: {{ .Values.oci.vcn }}

loadBalancer:
  # subnet1 configures one of two subnets to which load balancers will be added.
  # OCI load balancers require two subnets to ensure high availability.
  subnet1: {{ .Values.oci.loadbalancer.subnet1 }}

  # subnet2 configures the second of two subnets to which load balancers will be
  # added. OCI load balancers require two subnets to ensure high availability.
  subnet2: {{ .Values.oci.loadbalancer.subnet2 }}

  # SecurityListManagementMode configures how security lists are managed by the CCM.
  # If you choose to have security lists managed by the CCM, ensure you have setup the following additional OCI policy:
  # Allow dynamic-group [your dynamic group name] to manage security-lists in compartment [your compartment name]
  #
  #   "All" (default): Manage all required security list rules for load balancer services.
  #   "Frontend":      Manage only security list rules for ingress to the load
  #                    balancer. Requires that the user has setup a rule that
  #                    allows inbound traffic to the appropriate ports for kube
  #                    proxy health port, node port ranges, and health check port ranges.
  #                    E.g. 10.82.0.0/16 30000-32000.
  #   "None":          Disables all security list management. Requires that the
  #                    user has setup a rule that allows inbound traffic to the
  #                    appropriate ports for kube proxy health port, node port
  #                    ranges, and health check port ranges. E.g. 10.82.0.0/16 30000-32000.
  #                    Additionally requires the user to mange rules to allow
  #                    inbound traffic to load balancers.
  securityListManagementMode: {{ .Values.oci.loadbalancer.securitylistmanagementmode }}

  # Optional specification of which security lists to modify per subnet. This does not apply if security list management is off.
  #securityLists:
  #  ocid1.subnet.oc1.phx.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: ocid1.securitylist.oc1.iad.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  #  ocid1.subnet.oc1.phx.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: ocid1.securitylist.oc1.iad.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Optional rate limit controls for accessing OCI API
rateLimiter:
  rateLimitQPSRead: 20.0
  rateLimitBucketRead: 5
  rateLimitQPSWrite: 20.0
  rateLimitBucketWrite: 5
{{- end }}
