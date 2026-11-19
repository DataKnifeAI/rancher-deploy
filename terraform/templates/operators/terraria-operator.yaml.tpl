apiVersion: v1
kind: Namespace
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
    control-plane: controller-manager
  name: terraria-operator-system
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.17.2
  name: terrariaservers.terraria.dataknife.ai
spec:
  group: terraria.dataknife.ai
  names:
    kind: TerrariaServer
    listKind: TerrariaServerList
    plural: terrariaservers
    shortNames:
    - trs
    - terraria
    singular: terrariaserver
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
    - jsonPath: .status.installedTerrariaVersion
      name: Terraria
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
        description: TerrariaServer is the Schema for the terrariaservers API.
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
            description: TerrariaServerSpec defines the desired state of a Terraria
              dedicated server.
            properties:
              access:
                description: Access controls optional join password and whitelist.
                properties:
                  passwordSecretRef:
                    description: PasswordSecretRef refs a Secret with key "password"
                      for -pass.
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
                  whitelist:
                    description: Whitelist enables TShock whitelist mode when supported
                      by config.
                    type: boolean
                type: object
              adminAPI:
                description: AdminAPI controls TShock REST (7878, ClusterIP-only).
                properties:
                  enabled:
                    default: true
                    description: Enabled toggles REST on 7878. Default true; required
                      by Server Manager.
                    type: boolean
                  port:
                    default: 7878
                    description: Port overrides the REST listen port (default 7878).
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  tokenSecretRef:
                    description: |-
                      TokenSecretRef is a bring-your-own Secret with key "token".
                      When unset, the operator bootstraps an owned Secret via REST token create.
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
              backup:
                description: Backup configures an optional CronJob that tars the worlds
                  PVC.
                properties:
                  enabled:
                    description: Enabled creates a backup PVC + CronJob. Default false.
                    type: boolean
                  image:
                    default: busybox:1.36
                    description: Image is the backup job container image. Default
                      busybox:1.36.
                    type: string
                  restSaveFirst:
                    default: true
                    description: RESTSaveFirst when true (default) hits TShock REST
                      /save before tarring.
                    type: boolean
                  retain:
                    default: 7
                    description: Retain is how many compressed archives to keep. Default
                      7.
                    format: int32
                    maximum: 90
                    minimum: 1
                    type: integer
                  schedule:
                    default: 0 4 * * *
                    description: Schedule is a Cron expression (UTC). Default "0 4
                      * * *" (04:00 daily).
                    type: string
                  size:
                    default: 4Gi
                    description: Size is the backup PVC capacity. Default 4Gi.
                    type: string
                  storageClassName:
                    description: StorageClassName for the backup PVC. Empty inherits
                      persistence.storageClassName.
                    type: string
                type: object
              gateway:
                description: Gateway configures Envoy Gateway exposure (TCP 7777 only).
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
                    description: Enabled creates Gateway + TCPRoute resources. Default
                      true.
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
              nodeSelector:
                additionalProperties:
                  type: string
                description: NodeSelector pins the game server pod to specific nodes.
                type: object
              persistence:
                description: Persistence configures the worlds / tshock data PVC.
                properties:
                  existingClaim:
                    description: ExistingClaim adopts an existing PVC by name (DR
                      / restore).
                    type: string
                  size:
                    default: 4Gi
                    description: Size is the PVC capacity. Default 4Gi.
                    type: string
                  storageClassName:
                    description: StorageClassName selects the StorageClass. Empty
                      uses the cluster default.
                    type: string
                type: object
              plugins:
                description: Plugins mounts TShock plugin DLLs (owned PVC and/or URL
                  fetch).
                properties:
                  enabled:
                    description: Enabled mounts plugin storage into ServerPlugins/.
                    type: boolean
                  mountRef:
                    description: MountRef is a bring-your-own PVC name with DLLs (takes
                      precedence over owned PVC).
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
                  path:
                    description: Path overrides the container mount for ServerPlugins/.
                      Default /tshock/ServerPlugins.
                    type: string
                  size:
                    default: 1Gi
                    description: Size is the plugins PVC capacity when the operator
                      creates one. Default 1Gi.
                    type: string
                  urls:
                    description: URLs optionally fetch release artifacts (DLL/zip)
                      into ServerPlugins/ via init container.
                    items:
                      type: string
                    type: array
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
              serverImage:
                description: ServerImage selects the container image.
                properties:
                  image:
                    description: Image is the container image. Empty uses the default
                      for serverType.
                    type: string
                  pullPolicy:
                    default: IfNotPresent
                    description: PullPolicy for the game server container.
                    type: string
                type: object
              serverManager:
                description: ServerManager is an optional authenticated admin UI sidecar.
                properties:
                  enabled:
                    description: |-
                      Enabled starts the Server Manager sidecar and exposes its TCP port.
                      Default false. Enabling rolls the game StatefulSet.
                    type: boolean
                  hostname:
                    description: |-
                      Hostname is the public DNS name for HTTPS (must match the TLS cert SAN).
                      When set with tlsSecretRef, the operator creates Gateway + HTTPRoute.
                    type: string
                  httpsPort:
                    default: 443
                    description: HTTPSPort is the Gateway HTTPS listen port. Default
                      443.
                    format: int32
                    maximum: 65535
                    minimum: 1
                    type: integer
                  image:
                    description: |-
                      Image is the container image that provides /server-manager (the operator
                      image). Default: harbor.dataknife.net/library/terraria-operator:latest
                    type: string
                  port:
                    default: 8088
                    description: Port is the sidecar listen port (and Service TCP
                      port). Default 8088.
                    format: int32
                    maximum: 65535
                    minimum: 1024
                    type: integer
                  tlsSecretRef:
                    description: |-
                      TLSSecretRef is an existing kubernetes.io/tls Secret. Name is required when
                      hostname is set. Namespace defaults to the TerrariaServer namespace.
                    properties:
                      name:
                        description: name is unique within a namespace to reference
                          a secret resource.
                        type: string
                      namespace:
                        description: namespace defines the space within which the
                          secret name must be unique.
                        type: string
                    type: object
                    x-kubernetes-map-type: atomic
                type: object
              serverType:
                default: TSHOCK
                description: ServerType selects TSHOCK (default) or VANILLA (forces
                  ryshe-style image).
                enum:
                - TSHOCK
                - VANILLA
                type: string
              terminationGracePeriodSeconds:
                default: 60
                description: TerminationGracePeriodSeconds for clean world flush on
                  stop.
                format: int64
                minimum: 30
                type: integer
              update:
                description: Update configures the TShock release compat watcher /
                  opt-in image apply.
                properties:
                  autoUpdateImage:
                    description: |-
                      AutoUpdateImage when true patches version to PINNED at the latest TShock
                      release tag when an update is available (image roll via StatefulSet recreate).
                      Default false — opt-in only.
                    type: boolean
                  checkInterval:
                    default: 6h
                    description: CheckInterval is how often the reconciler polls TShock
                      GitHub releases.
                    type: string
                type: object
              version:
                description: Version controls STABLE vs PINNED image tags.
                properties:
                  mode:
                    default: STABLE
                    description: Mode selects STABLE (:stable tag) or PINNED (pinnedTag).
                    enum:
                    - STABLE
                    - PINNED
                    type: string
                  pinnedTag:
                    description: PinnedTag is the exact image tag when mode=PINNED
                      (e.g. "v6.1.0").
                    type: string
                type: object
              world:
                description: World maps to Terraria server command-line args.
                properties:
                  difficulty:
                    default: CLASSIC
                    description: 'Difficulty maps to -difficulty: CLASSIC=0, EXPERT=1,
                      MASTER=2, JOURNEY=3.'
                    enum:
                    - CLASSIC
                    - EXPERT
                    - MASTER
                    - JOURNEY
                    type: string
                  maxPlayers:
                    default: 16
                    description: MaxPlayers maps to -maxplayers.
                    format: int32
                    maximum: 255
                    minimum: 1
                    type: integer
                  name:
                    default: main
                    description: Name is the world name (-worldname) and .wld basename.
                    type: string
                  seed:
                    description: Seed is optional; blank means random.
                    type: string
                  size:
                    default: MEDIUM
                    description: 'Size maps to -autocreate: SMALL=1, MEDIUM=2, LARGE=3.'
                    enum:
                    - SMALL
                    - MEDIUM
                    - LARGE
                    type: string
                type: object
            type: object
          status:
            description: TerrariaServerStatus defines the observed state of TerrariaServer.
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
              connectionAddress:
                description: ConnectionAddress is the IP clients should use.
                type: string
              connectionPort:
                description: ConnectionPort is the TCP game port (default 7777).
                format: int32
                type: integer
              installedTerrariaVersion:
                description: InstalledTerrariaVersion is scraped from TShock REST
                  /logs or startup when known.
                type: string
              lastCommand:
                description: LastCommand is the last annotation command that was executed.
                type: string
              lastCommandResult:
                description: LastCommandResult is a short result / error for LastCommand.
                type: string
              lastUpdateCheck:
                description: LastUpdateCheck is when TShock GitHub releases were last
                  polled.
                format: date-time
                type: string
              latestTShockRelease:
                description: LatestTShockRelease is the newest TShock GitHub release
                  tag (without leading v).
                type: string
              latestTShockTerrariaVersion:
                description: LatestTShockTerrariaVersion is the Terraria version that
                  release supports.
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
              serverManagerAddress:
                description: ServerManagerAddress is the hostname or VIP for the optional
                  admin UI.
                type: string
              serverManagerPort:
                description: ServerManagerPort is the TCP/HTTPS port for the optional
                  admin UI.
                format: int32
                type: integer
              updateAvailable:
                description: UpdateAvailable is true when installed Terraria < latest
                  TShock-supported.
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
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-controller-manager
  namespace: terraria-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-leader-election-role
  namespace: terraria-operator-system
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
  name: terraria-operator-manager-role
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
  - serviceaccounts
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
  - batch
  resources:
  - cronjobs
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
  - httproutes
  - tcproutes
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - rbac.authorization.k8s.io
  resources:
  - rolebindings
  - roles
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers/finalizers
  verbs:
  - update
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers/status
  verbs:
  - get
  - patch
  - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: terraria-operator-metrics-auth-role
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
  name: terraria-operator-metrics-reader
rules:
- nonResourceURLs:
  - /metrics
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-terrariaserver-admin-role
rules:
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers
  verbs:
  - '*'
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-terrariaserver-editor-role
rules:
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-terrariaserver-viewer-role
rules:
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - terraria.dataknife.ai
  resources:
  - terrariaservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-leader-election-rolebinding
  namespace: terraria-operator-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: terraria-operator-leader-election-role
subjects:
- kind: ServiceAccount
  name: terraria-operator-controller-manager
  namespace: terraria-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
  name: terraria-operator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: terraria-operator-manager-role
subjects:
- kind: ServiceAccount
  name: terraria-operator-controller-manager
  namespace: terraria-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: terraria-operator-metrics-auth-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: terraria-operator-metrics-auth-role
subjects:
- kind: ServiceAccount
  name: terraria-operator-controller-manager
  namespace: terraria-operator-system
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
    control-plane: controller-manager
  name: terraria-operator-controller-manager-metrics-service
  namespace: terraria-operator-system
spec:
  ports:
  - name: https
    port: 8443
    protocol: TCP
    targetPort: 8443
  selector:
    app.kubernetes.io/name: terraria-operator
    control-plane: controller-manager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: terraria-operator
    control-plane: controller-manager
  name: terraria-operator-controller-manager
  namespace: terraria-operator-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: terraria-operator
      control-plane: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        app.kubernetes.io/name: terraria-operator
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
      serviceAccountName: terraria-operator-controller-manager
      terminationGracePeriodSeconds: 10
      volumes: []
