apiVersion: v1
kind: Namespace
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
    control-plane: controller-manager
  name: satisfactory-operator-system
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.17.2
  name: satisfactoryservers.satisfactory.dataknife.ai
spec:
  group: satisfactory.dataknife.ai
  names:
    kind: SatisfactoryServer
    listKind: SatisfactoryServerList
    plural: satisfactoryservers
    shortNames:
    - sfy
    - satisfactory
    singular: satisfactoryserver
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
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    name: v1alpha1
    schema:
      openAPIV3Schema:
        description: SatisfactoryServer is the Schema for the satisfactoryservers
          API.
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
              SatisfactoryServerSpec defines the desired state of a Satisfactory dedicated server.
              Configuration maps to the community robtme image environment variables.
            properties:
              backup:
                description: |-
                  Backup configures an optional CronJob that tars the data PVC into a
                  separate backup PVC (retain N archives).
                properties:
                  enabled:
                    description: Enabled creates a backup PVC + CronJob. Default false.
                    type: boolean
                  image:
                    default: busybox:1.36
                    description: Image is the backup job container image. Default
                      busybox:1.36.
                    type: string
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
                    description: Size is the backup PVC capacity. Default matches
                      persistence size.
                    type: string
                  storageClassName:
                    description: StorageClassName for the backup PVC. Empty inherits
                      persistence.storageClassName.
                    type: string
                type: object
              credentialsSecretRef:
                description: |-
                  CredentialsSecretRef names an existing Secret with key admin-password.
                  Required when serverManager.enabled and generateSecrets is false.
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
              gamePort:
                default: 7777
                description: |-
                  GamePort is SERVERGAMEPORT (TCP + UDP). Default 7777. Host and container
                  ports must match (Satisfactory does not support remapping the game port).
                format: int32
                maximum: 65535
                minimum: 1024
                type: integer
              gateway:
                description: Gateway configures Envoy Gateway exposure (or LoadBalancer
                  / NodePort).
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
                    default: false
                    description: |-
                      Enabled creates Gateway / UDPRoute / TCPRoute resources (Envoy Gateway).
                      Default false — Satisfactory (Unreal) joins often fail behind Envoy's UDP
                      proxy because the game sees the Envoy pod IP. Prefer serviceType=LoadBalancer
                      with address set to a kube-vip VIP instead.
                    type: boolean
                  envoyProxyName:
                    description: |-
                      EnvoyProxyName overrides the EnvoyProxy resource name.
                      Default: game-{base}-kubevip.
                    type: string
                  gatewayName:
                    description: |-
                      GatewayName overrides the Gateway resource name.
                      Default: {name}-gateway (strips a trailing "-server" suffix from name).
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
              generateSecrets:
                description: |-
                  GenerateSecrets when true creates an Opaque Secret with a random
                  admin-password key if missing (for optional Server Manager / future API
                  claim). Existing non-empty keys are never overwritten.
                type: boolean
              image:
                default: ghcr.io/robtme/satisfactory-server
                description: Image is the dedicated server container image repository.
                type: string
              imagePullPolicy:
                default: IfNotPresent
                description: ImagePullPolicy for the game server container.
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
              imageTag:
                description: |-
                  ImageTag pins an image tag. Empty uses the image as given (often :latest).
                  Prefer digests in production.
                type: string
              maxPlayers:
                default: 4
                description: MaxPlayers maps to MAXPLAYERS (1–16). Default 4.
                format: int32
                maximum: 16
                minimum: 1
                type: integer
              nodeSelector:
                additionalProperties:
                  type: string
                description: NodeSelector pins the game server pod to specific nodes.
                type: object
              persistence:
                description: Persistence configures the PVC mounted at /config.
                properties:
                  mountPath:
                    default: /config
                    description: 'MountPath is the container path for the PVC. robtme
                      default: /config'
                    type: string
                  size:
                    default: 40Gi
                    description: Size is the PVC capacity. Default 40Gi (gamefiles
                      ~15Gi + saves headroom).
                    type: string
                  storageClassName:
                    description: StorageClassName selects the StorageClass. Empty
                      uses the cluster default.
                    type: string
                type: object
              pgid:
                default: 1000
                description: PGID is the container process group id (PGID). Default
                  1000.
                format: int64
                type: integer
              puid:
                default: 1000
                description: PUID is the container process user id (PUID). Default
                  1000.
                format: int64
                type: integer
              reliablePort:
                default: 8888
                description: ReliablePort is SERVERMESSAGINGPORT (TCP). Default 8888
                  (wiki 1.1+).
                format: int32
                maximum: 65535
                minimum: 1024
                type: integer
              resources:
                description: Resources overrides auto-selected CPU/memory.
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
              serverManager:
                description: ServerManager is an optional authenticated admin UI sidecar.
                properties:
                  enabled:
                    description: |-
                      Enabled starts the Server Manager sidecar and exposes its TCP port.
                      Default false. Enabling Recreate-rolls the game Deployment.
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
                      image). Default: harbor.dataknife.net/library/satisfactory-operator:latest
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
                      hostname is set. Namespace defaults to the SatisfactoryServer namespace.
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
              serverName:
                description: |-
                  ServerName is a human display name (status / docs). In-game name is set
                  when claiming the server via the Satisfactory HTTPS API / client UI.
                type: string
              terminationGracePeriodSeconds:
                default: 60
                description: |-
                  TerminationGracePeriodSeconds is the SIGTERM grace window (default 60)
                  so the server can flush the world save on stop.
                format: int64
                minimum: 30
                type: integer
              update:
                description: Update configures SteamCMD / branch behaviour.
                properties:
                  autoUpdateImage:
                    description: |-
                      AutoUpdateImage is reserved for future digest/watch tooling. The robtme
                      image updates game files on start unless skipUpdate is true.
                    type: boolean
                  skipUpdate:
                    default: true
                    description: |-
                      SkipUpdate maps to SKIPUPDATE=true so container start does not pull a
                      multi-GB Steam update. Default true for cluster safety (opt-in updates).
                    type: boolean
                  steamBeta:
                    description: SteamBeta when true sets STEAMBETA=true (experimental
                      branch).
                    type: boolean
                type: object
            type: object
          status:
            description: SatisfactoryServerStatus defines the observed state of SatisfactoryServer.
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
                description: ConnectionPort is the game port clients should use (TCP+UDP).
                format: int32
                type: integer
              credentialsGenerated:
                description: CredentialsGenerated is true when generateSecrets manages
                  the Secret.
                type: boolean
              credentialsSecretName:
                description: |-
                  CredentialsSecretName is the Secret that holds admin-password when managed.
                  Never contains plaintext passwords.
                type: string
              imageVersion:
                description: ImageVersion is the running container image reference.
                type: string
              message:
                description: Message is a human-readable status detail.
                type: string
              observedGeneration:
                description: ObservedGeneration is the last reconciled generation.
                format: int64
                type: integer
              phase:
                description: Phase is Pending, Deploying, Running, VersionMismatch,
                  or Failed.
                type: string
              ready:
                description: Ready is true when the game server Deployment is available.
                type: boolean
              reliablePort:
                description: ReliablePort is the observed reliable messaging TCP port.
                format: int32
                type: integer
              serverManagerAddress:
                description: ServerManagerAddress is the IP for the optional admin
                  UI (usually the VIP).
                type: string
              serverManagerPort:
                description: ServerManagerPort is the TCP port for the optional admin
                  UI.
                format: int32
                type: integer
              serverName:
                description: ServerName echoes the configured display name.
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
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-controller-manager
  namespace: satisfactory-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-leader-election-role
  namespace: satisfactory-operator-system
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
  name: satisfactory-operator-manager-role
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
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
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - pods/log
  verbs:
  - get
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
  - udproutes
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
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers/finalizers
  verbs:
  - update
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers/status
  verbs:
  - get
  - patch
  - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: satisfactory-operator-metrics-auth-role
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
  name: satisfactory-operator-metrics-reader
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
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-satisfactoryserver-admin-role
rules:
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers
  verbs:
  - '*'
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-satisfactoryserver-editor-role
rules:
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-satisfactoryserver-viewer-role
rules:
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - satisfactory.dataknife.ai
  resources:
  - satisfactoryservers/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-leader-election-rolebinding
  namespace: satisfactory-operator-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: satisfactory-operator-leader-election-role
subjects:
- kind: ServiceAccount
  name: satisfactory-operator-controller-manager
  namespace: satisfactory-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
  name: satisfactory-operator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: satisfactory-operator-manager-role
subjects:
- kind: ServiceAccount
  name: satisfactory-operator-controller-manager
  namespace: satisfactory-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: satisfactory-operator-metrics-auth-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: satisfactory-operator-metrics-auth-role
subjects:
- kind: ServiceAccount
  name: satisfactory-operator-controller-manager
  namespace: satisfactory-operator-system
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
    control-plane: controller-manager
  name: satisfactory-operator-controller-manager-metrics-service
  namespace: satisfactory-operator-system
spec:
  ports:
  - name: https
    port: 8443
    protocol: TCP
    targetPort: 8443
  selector:
    app.kubernetes.io/name: satisfactory-operator
    control-plane: controller-manager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: satisfactory-operator
    control-plane: controller-manager
  name: satisfactory-operator-controller-manager
  namespace: satisfactory-operator-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: satisfactory-operator
      control-plane: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        app.kubernetes.io/name: satisfactory-operator
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
      - name: ${image_pull_secret}
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      serviceAccountName: satisfactory-operator-controller-manager
      terminationGracePeriodSeconds: 10
      volumes: []
