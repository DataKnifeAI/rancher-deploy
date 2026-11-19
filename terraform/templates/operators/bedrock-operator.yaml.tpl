apiVersion: v1
kind: Namespace
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
    control-plane: controller-manager
  name: bedrock-operator-system
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.17.2
  name: bedrockservers.bedrock.dataknife.ai
spec:
  group: bedrock.dataknife.ai
  names:
    kind: BedrockServer
    listKind: BedrockServerList
    plural: bedrockservers
    shortNames:
    - bds
    - bedrock
    singular: bedrockserver
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - jsonPath: .status.ready
      name: Ready
      type: boolean
    - jsonPath: .status.phase
      name: Phase
      type: string
    - jsonPath: .status.connectionAddress
      name: Address
      type: string
    - jsonPath: .status.connectionPort
      name: Port
      type: integer
    - jsonPath: .status.installedVersion
      name: Version
      type: string
    - jsonPath: .status.updateAvailable
      name: Update
      type: boolean
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    name: v1alpha1
    schema:
      openAPIV3Schema:
        description: BedrockServer is the Schema for the bedrockservers API.
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
            description: BedrockServerSpec defines the desired state of a Minecraft
              Bedrock dedicated server.
            properties:
              adminUI:
                description: AdminUI is Phase 3 — Server Manager UI (stub).
                properties:
                  enabled:
                    description: Enabled starts the Server Manager UI (Phase 3).
                    type: boolean
                type: object
              eula:
                description: 'EULA must be accepted (accepted: true) or reconcile
                  fails hard.'
                properties:
                  accepted:
                    description: Accepted must be true or reconcile fails and creates
                      no child resources.
                    type: boolean
                required:
                - accepted
                type: object
              gateway:
                description: Gateway configures Envoy Gateway exposure (UDP + NetherNet
                  TCP).
                properties:
                  address:
                    description: |-
                      Address is the dedicated external IP (Kube-VIP / MetalLB).
                      Required when enabled is true; also used as LoadBalancerIP when
                      enabled is false and serviceType is LoadBalancer.
                    pattern: ^$$|^([0-9]{1,3}\.){3}[0-9]{1,3}$$
                    type: string
                  className:
                    default: envoy
                    description: ClassName is the GatewayClass name.
                    type: string
                  enabled:
                    default: true
                    description: Enabled creates Gateway / UDPRoute / TCPRoute resources.
                      Default true.
                    type: boolean
                  envoyProxyName:
                    description: EnvoyProxyName overrides the EnvoyProxy resource
                      name.
                    type: string
                  gatewayName:
                    description: GatewayName overrides the Gateway resource name.
                    type: string
                  serviceType:
                    default: ClusterIP
                    description: ServiceType overrides the backing Service type when
                      gateway is disabled.
                    enum:
                    - ClusterIP
                    - NodePort
                    - LoadBalancer
                    type: string
                type: object
              hostNetworkDiscovery:
                description: |-
                  HostNetworkDiscovery opt-in sets hostNetwork for LAN discovery.
                  Document trade-offs: UDP broadcasts are not forwarded through pod networking.
                type: boolean
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
              mods:
                description: Mods is Phase 2 — pack/resource mounting (stub).
                properties:
                  enabled:
                    description: Enabled mounts packs into /data (Phase 2).
                    type: boolean
                type: object
              nodeSelector:
                additionalProperties:
                  type: string
                description: NodeSelector pins the game server pod to specific nodes.
                type: object
              persistence:
                description: Persistence configures the /data PVC.
                properties:
                  existingClaim:
                    description: ExistingClaim adopts an existing PVC by name (DR
                      / restore).
                    type: string
                  size:
                    default: 8Gi
                    description: Size is the PVC capacity. Default 8Gi.
                    type: string
                  storageClassName:
                    description: StorageClassName selects the StorageClass. Empty
                      uses the cluster default.
                    type: string
                type: object
              resources:
                description: Resources overrides default CPU/memory.
                properties:
                  claims:
                    description: |-
                      Claims lists the names of resources, defined in spec.resourceClaims,
                      that are used by this container.

                      This is an alpha field and requires enabling the
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
              secrets:
                description: Secrets configures operator/whitelist Secret material.
                properties:
                  allowList:
                    description: AllowList refs a Secret with key "allowlist.json"
                      (Bedrock whitelist file).
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
                  generateSecrets:
                    description: |-
                      GenerateSecrets creates an empty-owned Secret shell for operators/whitelist
                      when true. Bring-your-own refs take precedence when set.
                    type: boolean
                  operatorList:
                    description: OperatorList refs a Secret with key "operators.json"
                      mounted into /data permissions.
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
                type: object
              serverImage:
                description: ServerImage selects the runtime-download community image.
                properties:
                  image:
                    default: itzg/minecraft-bedrock-server:latest
                    description: 'Image is the container image. Default: itzg/minecraft-bedrock-server:latest'
                    type: string
                  pullPolicy:
                    default: IfNotPresent
                    description: PullPolicy for the game server container.
                    type: string
                type: object
              settings:
                description: Settings is a typed allow-list mapped to itzg env vars
                  / server.properties.
                properties:
                  allowCheats:
                    description: AllowCheats maps to ALLOW_CHEATS.
                    type: boolean
                  defaultPlayerPermissionLevel:
                    default: member
                    description: DefaultPlayerPermissionLevel maps to DEFAULT_PLAYER_PERMISSION_LEVEL.
                    enum:
                    - visitor
                    - member
                    - operator
                    type: string
                  difficulty:
                    default: normal
                    description: 'Difficulty maps to DIFFICULTY: peaceful | easy |
                      normal | hard.'
                    enum:
                    - peaceful
                    - easy
                    - normal
                    - hard
                    type: string
                  gameMode:
                    default: survival
                    description: 'GameMode maps to GAMEMODE: survival | creative |
                      adventure.'
                    enum:
                    - survival
                    - creative
                    - adventure
                    type: string
                  ipv6Enabled:
                    description: IPv6Enabled controls SERVER_PORT_V6 and a second
                      Gateway UDP listener (19133).
                    type: boolean
                  levelName:
                    description: LevelName maps to LEVEL_NAME.
                    type: string
                  levelSeed:
                    description: LevelSeed maps to LEVEL_SEED.
                    type: string
                  levelType:
                    default: DEFAULT
                    description: 'LevelType maps to LEVEL_TYPE: DEFAULT | FLAT | LEGACY.'
                    enum:
                    - DEFAULT
                    - FLAT
                    - LEGACY
                    type: string
                  maxPlayers:
                    default: 10
                    description: MaxPlayers maps to MAX_PLAYERS.
                    format: int32
                    maximum: 30
                    minimum: 1
                    type: integer
                  onlineMode:
                    default: true
                    description: |-
                      OnlineMode maps to ONLINE_MODE / online-mode. Default true (Xbox Live auth).
                      Set false only on trusted LAN for mcpelauncher testing when the Xbox
                      join/trust prompt never appears; remote clients may still require Xbox auth.
                    type: boolean
                  serverPort:
                    description: ServerPort overrides SERVER_PORT (default 19132).
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  serverPortV6:
                    description: ServerPortV6 overrides SERVER_PORT_V6 (default 19133).
                      Used when ipv6Enabled.
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  serverUdpPorts:
                    description: |-
                      ServerUdpPorts maps to SERVER_UDP_PORTS (NetherNet gameplay UDP).
                      Empty: operator derives "<gateway.address>:<start>-<end>:<start>-<end>"
                      with start=19140 and end=start+maxPlayers-1 (itzg NAT form so clients
                      reach the VIP). Ignored when transport=raknet.
                      Example: "192.168.14.190:19140-19149:19140-19149"
                    type: string
                  transport:
                    default: nethernet
                    description: |-
                      Transport maps to TRANSPORT / server.properties transport.
                      nethernet (default): required on BDS ≥1.26.60 — TCP /v1/join + UDP gameplay range.
                      raknet: legacy UDP on SERVER_PORT; BDS ≥1.26.60 refuses player joins.
                    enum:
                    - raknet
                    - nethernet
                    type: string
                  whiteList:
                    description: WhiteList maps to ALLOW_LIST (Bedrock 1.26+) and
                      WHITE_LIST (older images).
                    type: boolean
                type: object
              terminationGracePeriodSeconds:
                default: 60
                description: TerminationGracePeriodSeconds for clean world flush on
                  stop.
                format: int64
                minimum: 30
                type: integer
              update:
                description: Update configures the Mojang version-feed watcher.
                properties:
                  checkInterval:
                    default: 6h
                    description: CheckInterval is how often the reconciler polls the
                      Mojang download links API.
                    type: string
                  notifyOnly:
                    default: true
                    description: |-
                      NotifyOnly when true (default) only flips status.updateAvailable.
                      When false, the reconciler may patch version fields so the next pod
                      restart re-downloads (runtime-download analogue of autoUpdateImage).
                    type: boolean
                type: object
              version:
                description: Version controls BDS download selection (VERSION / DIRECT_DOWNLOAD_URL).
                properties:
                  directDownloadUrl:
                    description: |-
                      DirectDownloadUrl bypasses Mojang version lookup (air-gapped / pinned zip).
                      Maps to DIRECT_DOWNLOAD_URL on the itzg image.
                    type: string
                  mode:
                    default: LATEST
                    description: 'Mode selects VERSION env semantics: LATEST, PREVIEW,
                      PREVIOUS, or PINNED.'
                    enum:
                    - LATEST
                    - PREVIEW
                    - PREVIOUS
                    - PINNED
                    type: string
                  pinned:
                    description: Pinned is the exact BDS version when mode=PINNED
                      (e.g. "1.21.93.05").
                    type: string
                type: object
            required:
            - eula
            type: object
          status:
            description: BedrockServerStatus defines the observed state of BedrockServer.
            properties:
              availableVersion:
                description: AvailableVersion is the latest BDS version from the Mojang
                  feed.
                type: string
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
              connectionAddress:
                description: ConnectionAddress is the IP clients should use.
                type: string
              connectionPort:
                description: ConnectionPort is the UDP game port (default 19132).
                format: int32
                type: integer
              installedVersion:
                description: InstalledVersion is the version observed from the running
                  server when known.
                type: string
              lastUpdateCheck:
                description: LastUpdateCheck is when the Mojang feed was last polled.
                format: date-time
                type: string
              message:
                description: Message is a human-readable status detail.
                type: string
              observedGeneration:
                description: ObservedGeneration is the last reconciled generation.
                format: int64
                type: integer
              phase:
                description: Phase is Pending, Deploying, Running, or Failed.
                type: string
              ready:
                description: Ready is true when the StatefulSet has a ready replica.
                type: boolean
              updateAvailable:
                description: UpdateAvailable is true when availableVersion differs
                  from installedVersion.
                type: boolean
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
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-controller-manager
  namespace: bedrock-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-leader-election-role
  namespace: bedrock-operator-system
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
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-bedrockserver-admin-role
rules:
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers
  verbs:
  - '*'
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-bedrockserver-editor-role
rules:
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-bedrockserver-viewer-role
rules:
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bedrock-operator-manager-role
rules:
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - ""
  resources:
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
  - pods
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - apps
  resources:
  - statefulsets
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers/finalizers
  verbs:
  - update
- apiGroups:
  - bedrock.dataknife.ai
  resources:
  - bedrockservers/status
  verbs:
  - get
  - patch
  - update
- apiGroups:
  - gateway.envoyproxy.io
  resources:
  - envoyproxies
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - gateway.networking.k8s.io
  resources:
  - gatewayclasses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - gateway.networking.k8s.io
  resources:
  - gateways
  - tcproutes
  - udproutes
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bedrock-operator-metrics-auth-role
rules:
- apiGroups:
  - authentication.k8s.io
  resources:
  - tokenreviews
  verbs:
  - create
- apiGroups:
  - authorization.k8s.io
  resources:
  - subjectaccessreviews
  verbs:
  - create
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bedrock-operator-metrics-reader
rules:
- nonResourceURLs:
  - /metrics
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-leader-election-rolebinding
  namespace: bedrock-operator-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: bedrock-operator-leader-election-role
subjects:
- kind: ServiceAccount
  name: bedrock-operator-controller-manager
  namespace: bedrock-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
  name: bedrock-operator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: bedrock-operator-manager-role
subjects:
- kind: ServiceAccount
  name: bedrock-operator-controller-manager
  namespace: bedrock-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bedrock-operator-metrics-auth-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: bedrock-operator-metrics-auth-role
subjects:
- kind: ServiceAccount
  name: bedrock-operator-controller-manager
  namespace: bedrock-operator-system
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
    control-plane: controller-manager
  name: bedrock-operator-controller-manager-metrics-service
  namespace: bedrock-operator-system
spec:
  ports:
  - name: https
    port: 8443
    protocol: TCP
    targetPort: 8443
  selector:
    app.kubernetes.io/name: bedrock-operator
    control-plane: controller-manager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: bedrock-operator
    control-plane: controller-manager
  name: bedrock-operator-controller-manager
  namespace: bedrock-operator-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: bedrock-operator
      control-plane: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        app.kubernetes.io/name: bedrock-operator
        control-plane: controller-manager
    spec:
      containers:
      - args:
        - --metrics-bind-address=:8443
        - --leader-elect
        - --health-probe-bind-address=:8081
        command:
        - /manager
        image: ${operator_image}
        imagePullPolicy: Always
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
        name: manager
        ports: []
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
        volumeMounts: []
      imagePullSecrets:
      - name: harbor-registry-secret
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      serviceAccountName: bedrock-operator-controller-manager
      terminationGracePeriodSeconds: 10
      volumes: []
