# Copyright (c) 2015 iXsystems, Inc.
# All rights reserved.
# This file is a part of TrueNAS
# and may not be copied and/or distributed
# without the express permission of iXsystems.

import re
import subprocess

from freenasUI.network.models import Interfaces
from freenasUI.failover.detect import ha_node

from middlewared.alert.base import AlertClass, AlertCategory, AlertLevel, Alert, ThreadedAlertSource


class CriticalFailoverInterfaceNotFoundAlertClass(AlertClass):
    category = AlertCategory.HA
    level = AlertLevel.CRITICAL
    title = "Interface Is Critical for Failover but Was not Found In the System"
    text = "Interface %r is critical for failover but was not found in the system."


class CriticalFailoverInterfaceCARPNotConfiguredAlertClass(AlertClass):
    category = AlertCategory.HA
    level = AlertLevel.CRITICAL
    title = "Interface Is Critical for Failover but CARP Is not Configured"
    text = "Interface %r is critical for failover CARP is not configured."


class CriticalFailoverInterfaceCARPInvalidStateAlertClass(AlertClass):
    category = AlertCategory.HA
    level = AlertLevel.CRITICAL
    title = "Interface Is Critical for Failover but CARP Is not In a Valid State"
    text = "Interface %r is critical for failover CARP is not in a valid state."


class CriticalFailoverInterfaceInvalidVHIDAlertClass(AlertClass):
    category = AlertCategory.HA
    level = AlertLevel.CRITICAL
    title = "Interface Is Configured With Mismatching VHID"
    text = "Interface %(interface)r is configured with VHID %(vhid_real)d as opposed to %(vhid)d."


class FailedToVerifyCriticalFailoverInterfaceAlertClass(AlertClass):
    category = AlertCategory.HA
    level = AlertLevel.CRITICAL
    title = "Failed to Verify Interface by Contacting the Passive Node"
    text = "Failed to verify interface %r by contacting the passive node."


class FailoverCriticalAlertSource(ThreadedAlertSource):
    def check_sync(self):
        alerts = []

        if not self.middleware.call_sync('failover.licensed'):
            return alerts

        for iface in Interfaces.objects.filter(int_critical=True):
            proc = subprocess.Popen(
                ["/sbin/ifconfig", str(iface.int_interface)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                encoding='utf8',
            )
            output = proc.communicate()[0]
            if proc.returncode != 0:
                alerts.append(Alert(CriticalFailoverInterfaceNotFoundAlertClass, iface.int_interface))
                continue

            reg = re.search(r'carp: (\S+) .*vhid (\d+)', output, re.M)
            if not reg:
                alerts.append(Alert(CriticalFailoverInterfaceCARPNotConfiguredAlertClass, iface.int_interface))
            else:
                carp = reg.group(1)
                vhid = int(reg.group(2))
                if carp not in ('MASTER', 'BACKUP'):
                    alerts.append(Alert(CriticalFailoverInterfaceCARPInvalidStateAlertClass, iface.int_interface))
                if vhid != iface.int_vhid:
                    alerts.append(Alert(CriticalFailoverInterfaceInvalidVHIDAlertClass, {
                        'interface': iface.int_interface,
                        'vhid_real': vhid,
                        'vhid': iface.int_vhid
                    }))

            if not iface.int_dhcp:
                if ha_node() == 'B':
                    pingip = str(iface.int_ipv4address)
                    pingfrom = str(iface.int_ipv4address_b)
                else:
                    pingip = str(iface.int_ipv4address_b)
                    pingfrom = str(iface.int_ipv4address)

                ping = subprocess.Popen([
                    "/sbin/ping",
                    "-c", "1",
                    "-S", pingfrom,
                    "-t", "1",
                    pingip,
                ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                ping.communicate()
                if ping.returncode != 0:
                    alerts.append(Alert(FailedToVerifyCriticalFailoverInterfaceAlertClass, iface.int_interface))

        return alerts
