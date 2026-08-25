[Unit]
Description=DNS Shadow AI Collector (report to ASG Console + enforce DNS block)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/dns-shadow-ai/collector.py
Environment=ASG_CONSOLE_BASE=__ASG_CONSOLE_BASE__
Environment=ASG_COLLECTOR_TOKEN=__ASG_COLLECTOR_TOKEN__
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
