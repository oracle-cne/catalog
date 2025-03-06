%global debug_package %{nil}
%global _buildhost          build-ol%{?oraclelinux}-%{?_arch}.oracle.com

Name:		ocne-catalog
Version:	2.0.0
Release:	11%{?dist}
Summary:	An on-disk Helm chart repository

Group:		Development/Tools
License:	UPL 1.0
Source0:	%{name}-%{version}.tar.bz2

BuildRequires:	helm
BuildRequires:	make
BuildRequires:	findutils
BuildRequires:  yq

%description
An on-disk Helm chart repository

%prep
%setup -q


%build
make


%install
install -m 755 -d %{buildroot}/opt/charts
cp -r repo/* %{buildroot}/opt/charts
install -m 755 -d %{buildroot}/opt/icons
cp -ap olm/icons/* %{buildroot}/opt/icons

%files
/opt/charts
/opt/icons

%changelog
* Thu Mar 06 2025 Prasad Shirodkar <prasad.shirodkar@oracle.com> - 2.0.0-11
- Support DaemonSet for istio-ingress charts for 1.19.9 and 1.20.5

* Sun Feb 23 2025 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-10
- Add Flannel with floating tag
- Update Cluster API controllers
- Update Cert Manager
- Update OCI-CCM

* Wed Jan 29 2025 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-9
- Add CoreDNS
- Add Kube-Proxy

* Wed Nov 20 2024 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-8
- Improved some documentation

* Thu Oct 31 2024 Michael Gianatassio <michael.gianatassio@oracle.com> - 2.0.0-7
- Replace fluent-operator 2.5.0 with 3.2.0

* Wed Oct 23 2024 Michael Gianatassio <michael.gianatassio@oracle.com> - 2.0.0-6
- Add Fluentd
- Add Istio 1.19
- Remove requirement for Istio from Grafana

* Thu Oct 10 2024 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-5
- Add several applications

* Thu Sep 12 2024 Raaghav Wadhawan <raaghav.w.wadhawan@oracle.com> 2.0.0-4
- Update Dex and cert-manager-webhook-oci icons.

* Tue Sep 10 2024 Zaid Abdulrehman <zaid.a.abdulrehman@oracle.com> 2.0.0-3
- Change UI and catalog to use fully qualified images

* Fri Sep 06 2024 Daniel Krasinski <daniel.krasinski@oracle.com> 2.0.0-2
- Correct a few applications that did not properly annotate their container images

* Fri Aug 30 2024 Daniel Krasinski <daniel.krasinski@oracle.com> 2.0.0-1
- Applications for Oracle Cloud Native Environment
