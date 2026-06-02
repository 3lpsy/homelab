<configuration version="37">
    <gui enabled="true" tls="false" debugging="false">
        <address>0.0.0.0:8384</address>
        <user>${gui_user}</user>
        <password>__BCRYPT_PASSWORD__</password>
        <insecureAdminAccess>false</insecureAdminAccess>
        <theme>default</theme>
    </gui>
    <options>
        <listenAddress>tcp://0.0.0.0:22000</listenAddress>
        <globalAnnounceEnabled>false</globalAnnounceEnabled>
        <localAnnounceEnabled>false</localAnnounceEnabled>
        <relaysEnabled>false</relaysEnabled>
        <natEnabled>false</natEnabled>
        <urAccepted>-1</urAccepted>
        <crashReportingEnabled>false</crashReportingEnabled>
        <autoUpgradeIntervalH>0</autoUpgradeIntervalH>
        <startBrowser>false</startBrowser>
    </options>
%{ for name, device_id in trusted_devices ~}
%{ if device_id != "" ~}
    <device id="${device_id}" name="${name}" compression="metadata" introducer="false">
        <address>tcp://${lookup(tailnet_hostnames, name, name)}.${headscale_subdomain}.${headscale_magic_domain}:22000</address>
        <autoAcceptFolders>false</autoAcceptFolders>
    </device>
%{ endif ~}
%{ endfor ~}
    <folder id="ingest-music" label="ingest-music" path="/var/syncthing/folders/music" type="sendreceive">
        <fsWatcherEnabled>true</fsWatcherEnabled>
        <fsWatcherDelayS>10</fsWatcherDelayS>
        <rescanIntervalS>60</rescanIntervalS>
%{ for name, device_id in trusted_devices ~}
%{ if device_id != "" ~}
        <device id="${device_id}"/>
%{ endif ~}
%{ endfor ~}
    </folder>
</configuration>
