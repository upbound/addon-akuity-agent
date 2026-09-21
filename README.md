# Addon Akuity Agent

Upbound addon/controller package pair that registers an Upbound control plane
with [Akuity](https://akuity.io) and installs the Akuity Argo CD (or Kargo)
agent into it, so the control plane can be driven as an Argo CD cluster from the
Akuity Platform.

This exists because Akuity uses an **agent architecture**: components run inside
the target cluster rather than Argo CD reaching in with a kubeconfig. The
credentials a control plane exposes (`upbound:controlplane:admin`) cannot create
Deployments, Jobs, PodDisruptionBudgets or NetworkPolicies, so installing the
agent with the control plane's own connection secret always fails. Packaging it
as an AddOn/Controller moves the install to the platform, which has the
privileges — no admin kubeconfig handed to a control-plane user, and
`respectRBAC` never enters the picture.

## Which variant

|  | **Controller** | **AddOn** |
|---|---|---|
| Applied by | `mxp-controller`, as vcluster admin | `upbound-controller-manager`, inside the control plane |
| RBAC ceiling | none | the aggregate role — see below |
| `{{ .spaces.* }}` value templating | **yes** | **no** |
| Per-control-plane config | **none** — `clusterName` templates itself | an `AddOnRuntimeConfig` per control plane |
| Gate | `features.alpha.upboundControllers.enabled=true` (alpha, off by default) | `controlPlanes.uxp.enableAddons=true` |

**Prefer the Controller** wherever the feature is enabled. It is the only one of
the two that gives fleet-wide self-registration: the package value

```yaml
clusterName: "{{ .spaces.controlPlaneNamespace }}-{{ .spaces.controlPlaneName }}"
```

is templated per control plane by the Spaces `controllerrevision` reconciler, so
every control plane registers under its own unique Akuity cluster name with zero
per-control-plane configuration. The UXP `addonrevision` reconciler has no such
templating — it only merges package values with `AddOnRuntimeConfig` values — so
the AddOn variant needs one runtime config object per control plane.

## AddOn RBAC

On **Spaces >= v1.19** nothing extra is needed: SPA-791
([upbound/spaces#4376](https://github.com/upbound/spaces/pull/4376)) binds the
UXP v2 `upbound-controller-manager` to `cluster-admin` when addons are enabled.

On **older Spaces, and on UXP v1 control planes**, apply the companion role
below (also in the repo as `manifests/addon-cluster-role.yaml`).

It is a superset of the chart's own `akuity-agent-register` ClusterRole:
Kubernetes escalation-prevention only lets a subject create a role whose rules it
holds itself, so everything the chart grants has to appear here too.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: upbound-addon:akuity-agent
rules:
# --- What the AddOn reconciler applies directly (the Helm release itself) ---
- apiGroups:
  - ""
  resources:
  - namespaces
  verbs:
  - create
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - configmaps
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
# The register Job. This is the rule the stock aggregate is missing and the one
# that makes an unmodified Space reject this chart.
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
  - ""
  resources:
  - pods
  - pods/log
  - events
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - rbac.authorization.k8s.io
  resources:
  - clusterroles
  - clusterrolebindings
  - roles
  - rolebindings
  verbs:
  - bind
  - create
  - delete
  - escalate
  - get
  - list
  - patch
  - update
  - watch
# --- Superset of the chart's own `akuity-agent-register` ClusterRole ---
# (core namespaces/configmaps/secrets/services/serviceaccounts are covered above)
- apiGroups:
  - apps
  resources:
  - deployments
  - statefulsets
  verbs:
  - create
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - networkpolicies
  verbs:
  - create
  - get
  - list
  - patch
  - update
- apiGroups:
  - policy
  resources:
  - poddisruptionbudgets
  verbs:
  - create
  - get
  - list
  - patch
  - update
# Only used when agentType is "kargo", but the role has to carry it or the
# chart's role creation is refused on a Kargo install.
- apiGroups:
  - admissionregistration.k8s.io
  resources:
  - mutatingwebhookconfigurations
  verbs:
  - create
  - get
  - list
  - patch
  - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: upbound-addon:akuity-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: upbound-addon:akuity-agent
subjects:
- kind: ServiceAccount
  name: upbound-controller-manager
  namespace: crossplane-system
```

Applying it is a Space-operator action — a control-plane admin cannot create it
(escalation prevention). Measured on Spaces v1.17.3 against both a v1
(`1.20.10-up.1`) and a v2 (`2.1.8-up.4`) control plane, the aggregate is missing
`batch/jobs`, `policy/poddisruptionbudgets` and `networking.k8s.io/networkpolicies`.
`batch/jobs` is what actually breaks this chart — the controller manager already
holds `escalate` and `bind`, so it creates the chart's own ClusterRole fine and
then fails on the register Job.

## Credentials

The API key is **never** put in package values or a RuntimeConfig. The vendored
chart is patched (`patches/0001-existing-secret.patch`) to add the standard
`existingSecret` idiom, so the key can be delivered by a `SharedExternalSecret`
from the Space's secret store:

Apply this in the Space (the group namespace), not inside the control plane:

```yaml
apiVersion: spaces.upbound.io/v1alpha1
kind: SharedExternalSecret
metadata:
  name: akuity-agent-credentials
  namespace: default
spec:
  controlPlaneSelector:
    labelSelectors:
      - matchLabels:
          akuity.io/register: "true"
  namespaceSelector:
    names:
      - akuity
  externalSecretSpec:
    refreshInterval: 1h
    target:
      # Must match `existingSecret.name` in the package values.
      name: akuity-agent-credentials
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    data:
      - secretKey: AKUITY_API_KEY_ID
        remoteRef:
          key: /platform/akuity
          property: api_key_id
      - secretKey: AKUITY_API_KEY_SECRET
        remoteRef:
          key: /platform/akuity
          property: api_key_secret
```

**Ordering note.** Helm creates the release namespace (`akuity`) at install time
with `CreateNamespace`, so the Secret may not be projected there yet when the
pre-install Job is created. That is fine — the Job's pod stays in
`CreateContainerConfigError` and kubelet retries until the Secret appears, well
within the 10-minute Helm wait. To avoid the race entirely, set
`releaseNamespace` to a namespace the `SharedExternalSecret` already populates.

Neither `AddOnRuntimeConfig` nor `ControllerRuntimeConfig` supports
`valuesFrom`/`secretRef` (`spec.helm.values` is a free-form object and nothing
else), so without this patch the key would sit in plaintext in a CR in every
control plane. The same ~10-line change is worth asking Akuity to take upstream;
until they do, this package cannot ship the chart unmodified.

## Install

Both variants are applied in the Space. Every manifest below is also in the repo
under `examples/`.

### Controller (recommended)

The chart is applied by `mxp-controller` with the vcluster admin kubeconfig, so
there is no RBAC ceiling and no companion ClusterRole to apply. Requires
`features.alpha.upboundControllers.enabled=true` on the Space.

First the tenant configuration. `clusterName` is deliberately **not** set here —
the package templates it per control plane, so every control plane self-registers
under its own unique name with no per-control-plane configuration:

```yaml
apiVersion: pkg.upbound.io/v1alpha1
kind: ControllerRuntimeConfig
metadata:
  name: default
spec:
  helm:
    values:
      instanceName: my-argocd-instance
      organizationName: my-akuity-org
      # Self-hosted Akuity: point this at your own endpoint.
      # akuityServerUrl: https://akuity.example.com
      argocd:
        project: platform
```

Then the Controller itself:

```yaml
apiVersion: pkg.upbound.io/v1alpha1
kind: Controller
metadata:
  name: controller-akuity-agent
spec:
  package: xpkg.upbound.io/upbound/controller-akuity-agent:0.32.2
  # Picked up automatically — runtimeConfigRef defaults to name "default".
  runtimeConfigRef:
    name: default
```

### AddOn

For UXP control planes where the Controller feature is not enabled. On Spaces
< v1.19 apply the ClusterRole from [AddOn RBAC](#addon-rbac) first.

One `AddOnRuntimeConfig` is needed **per control plane** — `clusterName` must be
unique (Akuity rejects a second cluster registering under a name already taken)
and the AddOn path has no `{{ .spaces.* }}` value templating. If you provision
control planes from a composition, render this object there:

```yaml
apiVersion: pkg.upbound.io/v1beta1
kind: AddOnRuntimeConfig
metadata:
  name: default
spec:
  helm:
    values:
      clusterName: default-my-control-plane
      instanceName: my-argocd-instance
      organizationName: my-akuity-org
```

Then the AddOn itself:

```yaml
apiVersion: pkg.upbound.io/v1beta1
kind: AddOn
metadata:
  name: akuity-agent
spec:
  package: xpkg.upbound.io/upbound/addon-akuity-agent:0.32.2
  runtimeConfigRef:
    name: default
```

## What this package does not fix

The upstream chart is a **bootstrapper, not an install chart** — every resource
it renders is a `pre-install` hook. That is fine for installing (the Helm SDK
used by both reconcilers runs hooks and waits for the Job), but it has
consequences you should know before adopting this at scale:

- **The Helm release is empty.** Reconciles after install call `Upgrade`, and the
  chart has no `pre-upgrade` hook, so there is no drift correction and bumping
  the package version re-registers nothing.
- **Uninstall leaves the agent running.** `helm uninstall` removes nothing
  because there is nothing in the release; the cluster also stays registered in
  Akuity. Deleting the Controller/AddOn does delete the CRDs the package
  declares (and with them any `Application`/`AppProject` objects), but not the
  agent workloads. Deregistering is a manual step today.
- **Hook leftovers.** The Job is `hook-succeeded` so it is cleaned up, but the
  ServiceAccount, ClusterRole and ClusterRoleBinding are `before-hook-creation`
  only and stay behind untracked.
- **Egress is required.** The register Job must reach `akuity.cloud` (or your
  self-hosted Akuity) from inside the control plane, and it pulls
  `akuity-cli`. The agent images themselves are chosen by Akuity at registration
  time and are not part of the chart, so they cannot be mirrored or pinned here;
  `argocd.argoprojCustomImageRegistry` only redirects the argoproj images.

## Why this package ships Argo CD CRDs

`hack/pull-chart.sh` seeds `applications.argoproj.io` and
`appprojects.argoproj.io` (pinned by `ARGOCD_VERSION` in `.chart-attributes`)
into the chart's `crds/` directory. Two reasons:

1. `up xpkg build` refuses to build a **Controller** package containing no CRDs
   (`AtLeastOneCRD`, `up/internal/xpkg/lint.go`). The AddOn linter does not.
2. After install, the revision reconciler `GET`s every CRD the package declares —
   "we expect the CRDs to be created by the helm chart or the application
   itself" — and fails the revision if one is missing.

The Akuity agent bundle creates no CRDs at all: its register ClusterRole has no
`apiextensions` rule, and a customer's full apply log shows only namespaces,
service accounts, roles, deployments, services and PDBs. So the chart has to
provide them. Shipping them is also useful in its own right — it is what makes
`kubectl get applications` work in the control plane, it is a prerequisite for
`argocd.stateReplication`, and the reconciler renders Crossplane aggregate
ClusterRoles from them so control-plane users get RBAC on those types.

**Verify this against your Akuity agent version.** If Akuity ever starts
shipping its own copies, its `kubectl apply` wins and the seeded ones are just a
bootstrap; if it starts *requiring* a different Argo CD API version, bump
`ARGOCD_VERSION`.

## Images

| Upstream | Mirror |
|---|---|
| `quay.io/akuity/akuity-cli` | `xpkg.upbound.io/<org>/akuity-cli` |

The chart defaults to the `latest` tag, which this package deliberately does not
ship — `CLI_VERSION` in `.chart-attributes` pins it to the tag matching the chart
version.

## Development

### Building locally

```bash
source .chart-attributes
for t in addon controller; do
  mkdir -p $t-package/helm $t-package/crds
  cp $t.yaml $t-package/crossplane.yaml
  bash hack/pull-chart.sh $t-package/helm      # pull (OCI) + patch + seed CRDs
  # CRD extraction and `up xpkg build` — see .github/workflows/ci.yaml
done
```

`hack/pull-chart.sh` applies `patches/*.patch` with `patch --forward`, so a chart
bump that moves the anchors fails the build instead of silently shipping an
unpatched chart. Re-cut the patch against the new version when that happens.

### Testing

The e2e test **requires an Akuity tenant** — the pre-install Job registers
against akuity.cloud, so there is no offline path.

```bash
export AKUITY_API_KEY_ID=... AKUITY_API_KEY_SECRET=...
export AKUITY_ORGANIZATION=... AKUITY_INSTANCE=...
UP_CHART_VERSION=0.32.2 up test run tests/* --e2e
```

## Upstream

- Chart: `oci://quay.io/akuity/akuity-platform-charts/akuity-agent` v0.32.2
- Docs: https://docs.akuity.io/akuity-portal/automation/agent-helm-chart
- Related: Pylon #1904, SPA-900, SPA-791, SPA-589, SPA-792
