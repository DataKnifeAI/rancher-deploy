apiVersion: v1
kind: Namespace
metadata:
  labels:
    app.kubernetes.io/name: stoat-operator
    control-plane: controller-manager
  name: stoat-operator-system
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
  name: stoats.stoat.dataknife.ai
spec:
  group: stoat.dataknife.ai
  names:
    kind: Stoat
    listKind: StoatList
    plural: stoats
    shortNames:
    - st
    singular: stoat
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - jsonPath: .status.phase
      name: Phase
      type: string
    - jsonPath: .status.ready
      name: Ready
      type: boolean
    - jsonPath: .spec.domain
      name: Domain
      type: string
    - jsonPath: .status.observedVersion
      name: Version
      type: string
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    name: v1alpha1
    schema:
      openAPIV3Schema:
        description: |-
          Stoat is the Schema for the stoats API — an umbrella CR for a self-hosted
          Stoat chat instance (API, web, files, push, voice, and dependencies).
        properties:
          apiVersion:
            description: |-
              APIVersion defines the versioned schema of this representation of an object.
              Servers should convert recognized schemas to the latest internal value, and
              may reject unrecognized values.
              More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
            type: string
          kind:
            description: |-
              Kind is a string value representing the REST resource this object represents.
              Servers may infer this from the endpoint the client submits requests to.
              Cannot be updated.
              In CamelCase.
              More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
            type: string
          metadata:
            type: object
          spec:
            description: |-
              StoatSpec defines the desired state of a Stoat instance.
              Models the upstream self-hosted compose stack as a single umbrella CR:
              https://github.com/stoatchat/self-hosted
            properties:
              admin:
                description: Admin configures the optional admin panel (Authentik
                  SSO, separate Ingress).
                properties:
                  credentialsSecret:
                    description: |-
                      CredentialsSecret names a Secret with Authentik + NextAuth keys:
                      authentikId, authentikSecret, authentikIssuer (no trailing slash),
                      and optional nextAuthSecret (generated into stoat-admin-env when missing).
                    type: string
                  domain:
                    description: |-
                      Domain is the public hostname for the admin Ingress
                      (e.g. stoat-admin.dataknife.net). Required when Enabled.
                    type: string
                  enabled:
                    default: false
                    description: Enabled deploys the admin panel when true.
                    type: boolean
                  platformAccountId:
                    description: |-
                      PlatformAccountId is the Stoat user ULID used as PLATFORM_ACCOUNT_ID
                      for admin-originated platform DMs / actions.
                    type: string
                  tlsSecretName:
                    description: |-
                      TLSSecretName optionally sets Ingress TLS for the admin host.
                      When empty, falls back to spec.ingress.tlsSecretName.
                    type: string
                type: object
              dependencies:
                description: Dependencies configures MongoDB, Valkey/Redis, RabbitMQ,
                  and object storage.
                properties:
                  embed:
                    default: true
                    description: Embed provisions in-cluster dependency workloads
                      when true.
                    type: boolean
                  mongodb:
                    description: MongoDB external connection (overrides embed for
                      MongoDB when set).
                    properties:
                      secretRef:
                        description: SecretRef holds credentials (connection URI,
                          passwords, keys).
                        properties:
                          key:
                            description: The key of the secret to select from.  Must
                              be a valid secret key.
                            type: string
                          name:
                            default: ""
                            description: |-
                              Name of the referent.
                              This field is effectively required, but due to backwards compatibility is
                              allowed to be empty. Instances of this type with an empty value here are
                              almost certainly wrong.
                              More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                            type: string
                          optional:
                            description: Specify whether the Secret or its key must
                              be defined
                            type: boolean
                        required:
                        - key
                        type: object
                        x-kubernetes-map-type: atomic
                      uri:
                        description: URI is a connection string or host URL for the
                          dependency.
                        type: string
                    type: object
                  objectStorage:
                    description: |-
                      ObjectStorage selects Autumn's S3 backend.
                      Omit for embedded MinIO/Silo; set endpoint + credentialsSecret for
                      external S3 (e.g. RustFS on TrueNAS).
                    properties:
                      bucket:
                        default: revolt-uploads
                        description: Bucket is the S3 bucket name for encrypted uploads.
                        type: string
                      credentialsSecret:
                        description: |-
                          CredentialsSecret names a Secret with keys accessKeyId and secretAccessKey.
                          Required when Endpoint is set to an external service.
                        type: string
                      endpoint:
                        description: |-
                          Endpoint is the S3 API URL (no trailing slash), e.g. https://rustfs.example:30292
                          or http://minio:9000 for the embedded service.
                        type: string
                      pathStyleBuckets:
                        default: true
                        description: |-
                          PathStyleBuckets enables path-style addressing (bucket in URL path).
                          Default true — required for Kubernetes and most S3-compatible stores
                          (RustFS, etc.). Docker Compose MinIO often uses virtual-host style instead.
                        type: boolean
                      region:
                        default: minio
                        description: Region is the S3 region string written into Revolt.toml.
                        type: string
                    type: object
                  rabbitmq:
                    description: RabbitMQ external connection.
                    properties:
                      secretRef:
                        description: SecretRef holds credentials (connection URI,
                          passwords, keys).
                        properties:
                          key:
                            description: The key of the secret to select from.  Must
                              be a valid secret key.
                            type: string
                          name:
                            default: ""
                            description: |-
                              Name of the referent.
                              This field is effectively required, but due to backwards compatibility is
                              allowed to be empty. Instances of this type with an empty value here are
                              almost certainly wrong.
                              More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                            type: string
                          optional:
                            description: Specify whether the Secret or its key must
                              be defined
                            type: boolean
                        required:
                        - key
                        type: object
                        x-kubernetes-map-type: atomic
                      uri:
                        description: URI is a connection string or host URL for the
                          dependency.
                        type: string
                    type: object
                  redis:
                    description: Redis/Valkey external connection.
                    properties:
                      secretRef:
                        description: SecretRef holds credentials (connection URI,
                          passwords, keys).
                        properties:
                          key:
                            description: The key of the secret to select from.  Must
                              be a valid secret key.
                            type: string
                          name:
                            default: ""
                            description: |-
                              Name of the referent.
                              This field is effectively required, but due to backwards compatibility is
                              allowed to be empty. Instances of this type with an empty value here are
                              almost certainly wrong.
                              More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                            type: string
                          optional:
                            description: Specify whether the Secret or its key must
                              be defined
                            type: boolean
                        required:
                        - key
                        type: object
                        x-kubernetes-map-type: atomic
                      uri:
                        description: URI is a connection string or host URL for the
                          dependency.
                        type: string
                    type: object
                type: object
              domain:
                description: Domain is the public hostname for this Stoat instance
                  (e.g. chat.example.com).
                minLength: 1
                type: string
              generateSecrets:
                default: true
                description: |-
                  GenerateSecrets when true creates an owned Secret with Stoat encryption
                  keys and service passwords. Losing these secrets can permanently lock
                  file access — back them up.
                type: boolean
              gifbox:
                description: |-
                  Gifbox configures the GIF picker upstream (Gifbox Compatibility API).
                  Without an API key, gifbox panics on search/trending against compat.gifbox.me.
                  Create a key at https://gifbox.me/settings after signing in.
                properties:
                  credentialsSecret:
                    description: |-
                      CredentialsSecret names a Secret with key apiKey (Gifbox Compatibility API key).
                      Synced into stoat-secrets as REVOLT__API__SECURITY__TENOR_KEY for gifbox/api.
                    type: string
                type: object
              imagePullPolicy:
                default: IfNotPresent
                description: ImagePullPolicy for Stoat component containers.
                type: string
              imagePullSecrets:
                description: ImagePullSecrets for private registries.
                items:
                  description: |-
                    LocalObjectReference contains enough information to let you locate the
                    referenced object inside the same namespace.
                  properties:
                    name:
                      default: ""
                      description: |-
                        Name of the referent.
                        This field is effectively required, but due to backwards compatibility is
                        allowed to be empty. Instances of this type with an empty value here are
                        almost certainly wrong.
                        More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
                      type: string
                  type: object
                  x-kubernetes-map-type: atomic
                type: array
              images:
                description: Images optionally overrides individual component images.
                properties:
                  adminPanel:
                    description: AdminPanel is the Stoat admin panel image (DataKnifeAI/stoat-admin).
                    type: string
                  api:
                    description: API is the Stoat API server image.
                    type: string
                  autumn:
                    description: Autumn is the file server (autumn) image.
                    type: string
                  crond:
                    description: Crond is the task daemon image.
                    type: string
                  events:
                    description: Events is the Stoat events service image.
                    type: string
                  gifbox:
                    description: Gifbox is the Tenor proxy image.
                    type: string
                  january:
                    description: January is the metadata/image proxy image.
                    type: string
                  livekit:
                    description: LiveKit is the LiveKit server image.
                    type: string
                  pushd:
                    description: Pushd is the push notification daemon image.
                    type: string
                  voiceIngress:
                    description: VoiceIngress is the voice ingress daemon image.
                    type: string
                  web:
                    description: Web is the for-web front-end image.
                    type: string
                type: object
              ingress:
                description: Ingress configures HTTP(S) exposure for web and API.
                properties:
                  annotations:
                    additionalProperties:
                      type: string
                    description: Annotations applied to the Ingress / HTTPRoute resources.
                    type: object
                  className:
                    default: nginx
                    description: ClassName is the IngressClass or GatewayClass name.
                    type: string
                  tlsSecretName:
                    description: TLSSecretName is an optional TLS Secret for HTTPS
                      termination.
                    type: string
                type: object
              livekit:
                description: LiveKit configures voice/RTC networking.
                properties:
                  address:
                    description: |-
                      Address is an optional stable LAN/VPN IP advertised to clients for RTC ICE
                      (typically a kube-vip / MetalLB VIP). When empty, LiveKit advertises the
                      scheduled node's LAN address (status.hostIP). Not a cluster-internal IP.
                      When set with serviceType=LoadBalancer, pin LiveKit onto the VIP host via
                      nodeName (or ensure kube-vip moves the VIP onto LiveKit's node) — otherwise
                      ICE advertises the VIP while UDP/TCP 7881 listen on a different node.
                    type: string
                  enabled:
                    default: true
                    description: |-
                      Enabled toggles LiveKit / voice-ingress workloads and advertises voice
                      endpoints in Revolt.toml / Caddy. When false, voice config and routes are omitted.
                    type: boolean
                  latitude:
                    description: Latitude of this LiveKit node (used by Stoat for
                      nearest-node selection).
                    type: number
                  longitude:
                    description: Longitude of this LiveKit node (used by Stoat for
                      nearest-node selection).
                    type: number
                  nodeName:
                    description: |-
                      NodeName pins the LiveKit hostNetwork pod to a specific node. Required when
                      Address is a kube-vip VIP with externalTrafficPolicy=Local: LiveKit must
                      run on the same node that holds the VIP or clients cannot complete ICE.
                    type: string
                  rtcPort:
                    default: 7881
                    description: RTCPort is the LiveKit TCP RTC port (hostNetwork).
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  serviceType:
                    default: ClusterIP
                    description: |-
                      ServiceType for the optional RTC exposure Service (livekit-rtc).
                      Signaling stays ClusterIP for Caddy. Use LoadBalancer with address set
                      to claim a kube-vip VIP for TCP 7881 + the UDP media range.
                    enum:
                    - ClusterIP
                    - NodePort
                    - LoadBalancer
                    type: string
                  udpPortEnd:
                    default: 50100
                    description: UDPPortEnd is the last UDP port in the RTC media
                      range (hostNetwork).
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  udpPortStart:
                    default: 50000
                    description: UDPPortStart is the first UDP port in the RTC media
                      range (hostNetwork).
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  useExternalIP:
                    default: false
                    description: |-
                      UseExternalIP discovers a public WAN IP via STUN for RTC candidates.
                      Leave false (default) for site-local access: clients on the LAN/VPN reach
                      LiveKit on the node (or VIP) address. This is not ClusterIP-only — media
                      still uses hostNetwork on the local network, not the pod network.
                    type: boolean
                type: object
              nodeSelector:
                additionalProperties:
                  type: string
                description: NodeSelector pins Stoat pods to specific nodes.
                type: object
              resources:
                description: Resources applied as defaults to app containers when
                  set.
                properties:
                  claims:
                    description: |-
                      Claims lists the names of resources, defined in spec.resourceClaims,
                      that are used by this container.

                      This field depends on the
                      DynamicResourceAllocation feature gate.

                      This field is immutable. It can only be set for containers.
                    items:
                      description: ResourceClaim references one entry in PodSpec.ResourceClaims.
                      properties:
                        name:
                          description: |-
                            Name must match the name of one entry in pod.spec.resourceClaims of
                            the Pod where this field is used. It makes that resource available
                            inside a container.
                          type: string
                        request:
                          description: |-
                            Request is the name chosen for a request in the referenced claim.
                            If empty, everything from the claim is made available, otherwise
                            only the result of this request.
                          type: string
                      required:
                      - name
                      type: object
                    type: array
                    x-kubernetes-list-map-keys:
                    - name
                    x-kubernetes-list-type: map
                  limits:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$$
                      x-kubernetes-int-or-string: true
                    description: |-
                      Limits describes the maximum amount of compute resources allowed.
                      More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                    type: object
                  requests:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$$
                      x-kubernetes-int-or-string: true
                    description: |-
                      Requests describes the minimum amount of compute resources required.
                      If Requests is omitted for a container, it defaults to Limits if that is explicitly specified,
                      otherwise to an implementation-defined value. Requests cannot exceed Limits.
                      More info: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
                    type: object
                type: object
              scaling:
                description: |-
                  Scaling configures horizontal replicas for stateless components.
                  Set replicas: 2 (or higher) for app-tier HA behind Services/Ingress.
                properties:
                  adminPanel:
                    description: AdminPanel overrides replicas for the admin panel.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  api:
                    description: API overrides replicas for the API deployment.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  autumn:
                    description: Autumn overrides replicas for the file server.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  caddy:
                    description: Caddy overrides replicas for the edge proxy.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  events:
                    description: Events overrides replicas for the events deployment.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  gifbox:
                    description: Gifbox overrides replicas for gifbox.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  january:
                    description: January overrides replicas for the proxy.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  pushd:
                    description: Pushd overrides replicas for push notifications.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  replicas:
                    default: 1
                    description: |-
                      Replicas is the default replica count for scalable app components
                      (api, events, autumn, january, gifbox, web, caddy, pushd, admin-panel).
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                  web:
                    description: Web overrides replicas for the for-web front-end.
                    format: int32
                    maximum: 20
                    minimum: 1
                    type: integer
                type: object
              secretsRef:
                description: |-
                  SecretsRef names an existing Secret with Stoat keys (skips generation).
                  Expected keys align with upstream secrets.env.
                type: string
              storage:
                description: Storage configures PVC defaults for embedded data services.
                properties:
                  size:
                    default: 20Gi
                    description: Size is the default PVC request for embedded data
                      volumes.
                    type: string
                  storageClassName:
                    description: StorageClassName selects the StorageClass for PVCs.
                    type: string
                type: object
              version:
                default: v0.16.2
                description: Version pins the Stoat component image tag family (e.g.
                  v0.16.2).
                type: string
            required:
            - domain
            type: object
          status:
            description: StoatStatus defines the observed state of Stoat.
            properties:
              conditions:
                description: Conditions represent the latest available observations.
                items:
                  description: Condition contains details for one aspect of the current
                    state of this API Resource.
                  properties:
                    lastTransitionTime:
                      description: |-
                        lastTransitionTime is the last time the condition transitioned from one status to another.
                        This should be when the underlying condition changed.  If that is not known, then using the time when the API field changed is acceptable.
                      format: date-time
                      type: string
                    message:
                      description: |-
                        message is a human readable message indicating details about the transition.
                        This may be an empty string.
                      maxLength: 32768
                      type: string
                    observedGeneration:
                      description: |-
                        observedGeneration represents the .metadata.generation that the condition was set based upon.
                        For instance, if .metadata.generation is currently 12, but the .status.conditions[x].observedGeneration is 9, the condition is out of date
                        with respect to the current state of the instance.
                      format: int64
                      minimum: 0
                      type: integer
                    reason:
                      description: |-
                        reason contains a programmatic identifier indicating the reason for the condition's last transition.
                        Producers of specific condition types may define expected values and meanings for this field,
                        and whether the values are considered a guaranteed API.
                        The value should be a CamelCase string.
                        This field may not be empty.
                      maxLength: 1024
                      minLength: 1
                      pattern: ^[A-Za-z]([A-Za-z0-9_,:]*[A-Za-z0-9_])?$$
                      type: string
                    status:
                      description: status of the condition, one of True, False, Unknown.
                      enum:
                      - "True"
                      - "False"
                      - Unknown
                      type: string
                    type:
                      description: type of condition in CamelCase or in foo.example.com/CamelCase.
                      maxLength: 316
                      pattern: ^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])$$
                      type: string
                  required:
                  - lastTransitionTime
                  - message
                  - reason
                  - status
                  - type
                  type: object
                type: array
              message:
                description: Message provides human-readable status details.
                type: string
              observedVersion:
                description: ObservedVersion is the Stoat version currently reconciled.
                type: string
              phase:
                description: Phase summarizes high-level lifecycle state.
                type: string
              ready:
                description: Ready indicates the instance is serving traffic.
                type: boolean
              url:
                description: URL is the public web URL derived from spec.domain.
                type: string
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/name: stoat-operator
  name: stoat-operator-controller-manager
  namespace: stoat-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/name: stoat-operator
  name: stoat-operator-leader-election-role
  namespace: stoat-operator-system
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: stoat-operator-manager-role
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  - persistentvolumeclaims
  - secrets
  - services
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - apps
  resources:
  - deployments
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - batch
  resources:
  - jobs
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - stoat.dataknife.ai
  resources:
  - stoats
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - stoat.dataknife.ai
  resources:
  - stoats/finalizers
  verbs:
  - update
- apiGroups:
  - stoat.dataknife.ai
  resources:
  - stoats/status
  verbs:
  - get
  - patch
  - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/name: stoat-operator
  name: stoat-operator-leader-election-rolebinding
  namespace: stoat-operator-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: stoat-operator-leader-election-role
subjects:
- kind: ServiceAccount
  name: stoat-operator-controller-manager
  namespace: stoat-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/name: stoat-operator
  name: stoat-operator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: stoat-operator-manager-role
subjects:
- kind: ServiceAccount
  name: stoat-operator-controller-manager
  namespace: stoat-operator-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/name: stoat-operator
    control-plane: controller-manager
  name: stoat-operator-controller-manager
  namespace: stoat-operator-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: stoat-operator
      control-plane: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        app.kubernetes.io/name: stoat-operator
        control-plane: controller-manager
    spec:
      containers:
      - args:
        - --leader-elect
        - --health-probe-bind-address=:8081
        command:
        - /manager
        image: ${operator_image}
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
        name: manager
        ports:
        - containerPort: 8443
          name: metrics
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
          requests:
            cpu: 10m
            memory: 128Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      serviceAccountName: stoat-operator-controller-manager
      terminationGracePeriodSeconds: 10
