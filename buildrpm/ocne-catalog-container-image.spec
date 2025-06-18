%global debug_package %{nil}
%global _buildhost          build-ol%{?oraclelinux}-%{?_arch}.oracle.com
%global registry container-registry.oracle.com/olcne
%global _name ocne-catalog
%global rpm_name %{_name}-%{version}-%{release}.%{_build_arch}
%global docker_tag %{registry}/%{_name}:v%{version}

Name:		%{_name}-container-image
Version:	2.0.0
Release:	14%{?dist}
Summary:	An on-disk Helm chart repository

Group:		Development/Tools
License:	UPL 1.0
Source0:	%{name}-%{version}.tar.bz2

%description
An on-disk Helm chart repository

%prep
%setup -q

%build
yum clean all
yumdownloader --destdir=${PWD}/rpms %{rpm_name}

docker build --pull=never --squash --build-arg https_proxy=${https_proxy} \
	-t %{docker_tag} -f ./olm/builds/Dockerfile .
docker save -o %{_name}.tar %{docker_tag}

%install
%__install -D -m 644 %{_name}.tar %{buildroot}/usr/local/share/olcne/%{_name}.tar

%files
/usr/local/share/olcne/%{_name}.tar

%clean

%changelog
* Wed Jun 18 2025 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-14
- Rebuild with latest Oracle Linux 8 base image

* Sat Apr 05 2025 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-13
- Use common base image

* Thu Mar 06 2025 Prasad Shirodkar <prasad.shirodkar@oracle.com> - 2.0.0-12
- Added Kubernetes Gateway API CRDs 1.2.1

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
