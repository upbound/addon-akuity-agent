# End-to-end test for the Akuity agent AddOn.
#
# REQUIRES AN AKUITY TENANT. The chart's pre-install Job calls
# `akuity argocd cluster create` against akuity.cloud, so unlike most addon
# packages this test cannot pass offline. It needs, in the environment:
#
#   UP_CHART_VERSION       package version under test
#   AKUITY_API_KEY_ID      Akuity API key ID
#   AKUITY_API_KEY_SECRET  Akuity API key secret
#   AKUITY_ORGANIZATION    Akuity organization name
#   AKUITY_INSTANCE        Argo CD instance name in that organization
#
# The Secret below stands in for the SharedExternalSecret used in production —
# it is the same contract (`existingSecret.name`), just populated by the test.
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.k8s.api.rbac.v1 as rbacv1
import models.io.k8s.api.core.v1 as corev1
import file

version = file.read_env("UP_CHART_VERSION")
apiKeyId = file.read_env("AKUITY_API_KEY_ID")
apiKeySecret = file.read_env("AKUITY_API_KEY_SECRET")
organization = file.read_env("AKUITY_ORGANIZATION")
instance = file.read_env("AKUITY_INSTANCE")

# Akuity cluster names must be unique within an instance, and the AddOn path
# cannot template one per control plane, so the test pins its own.
clusterName = "up-e2e-akuity-agent"

_items = [
    metav1alpha1.E2ETest{
        metadata.name: "addon-akuity-agent"
        spec = {
            crossplane.autoUpgrade.channel: "Rapid"
            defaultConditions: ["Installed", "Healthy"]
            initResources: [
                # Stands in for SPA-791 on Spaces < v1.19. On v1.19+ with addons
                # enabled the platform already binds cluster-admin and this is a
                # no-op; manifests/addon-cluster-role.yaml is the least-privilege
                # alternative for a real installation.
                rbacv1.ClusterRoleBinding{
                    metadata.name: "upbound-controller-manager-cluster-admin"
                    roleRef: {
                        apiGroup: "rbac.authorization.k8s.io"
                        kind: "ClusterRole"
                        name: "cluster-admin"
                    }
                    subjects: [
                        {
                            kind: "ServiceAccount"
                            name: "upbound-controller-manager"
                            namespace: "crossplane-system"
                        }
                    ]
                }
                # Helm would create this namespace itself, but the credentials
                # Secret has to land somewhere first.
                corev1.Namespace{
                    metadata.name: "akuity"
                }
                corev1.Secret{
                    metadata: {
                        name: "akuity-agent-credentials"
                        namespace: "akuity"
                    }
                    type: "Opaque"
                    stringData: {
                        AKUITY_API_KEY_ID: apiKeyId
                        AKUITY_API_KEY_SECRET: apiKeySecret
                    }
                }
            ]
            manifests: [
                {
                    apiVersion: "pkg.upbound.io/v1beta1"
                    kind: "AddOnRuntimeConfig"
                    metadata.name: "default"
                    spec.helm.values: {
                        clusterName: clusterName
                        instanceName: instance
                        organizationName: organization
                    }
                }
                {
                    apiVersion: "pkg.upbound.io/v1beta1"
                    kind: "AddOn"
                    metadata.name: "pkg-addon-akuity-agent"
                    spec.package: "xpkg.upbound.io/upbound/addon-akuity-agent:" + version
                }
            ]
            extraResources: []
            skipDelete: False
            timeoutSeconds: 1800
        }
    }
]
items = _items
