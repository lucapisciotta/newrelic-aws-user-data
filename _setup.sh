#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive
IFS=""  # Used to write array's tags in the correct way

# Prepare the system installing jq, cloud-utils and awscli
listRequiredPackages=(jq aws ec2metadata)

for package in ${listRequiredPackages[*]}
do
    if ! command -v "$package" > /dev/null ; then
        if [ "aws" == "$package" ]; then
            apt -qq update
            apt -qq -o=Dpkg::Use-Pty=0 install --no-install-suggests --no-install-recommends  -y "$package"cli
        fi
        if [ "ec2metadata" == "$package" ]; then
            apt -qq update
            apt -qq -o=Dpkg::Use-Pty=0 install --no-install-suggests --no-install-recommends -y cloud-utils
        fi
        if [ "aws" != "$package" ] && [ "ec2metadata" != "$package" ]; then
            apt -qq update
            apt -qq -o=Dpkg::Use-Pty=0 install --no-install-suggests --no-install-recommends -y "$package"
        fi
        echo "Package $package installed"
    else
        echo "Package $package already installed"
    fi
done

osCodeName=$(< /etc/os-release  grep VERSION_CODENAME | cut -d'=' -f2)
servicesList=(newrelic-infra td-agent-bit)
instanceId="$(ec2metadata --instance-id)"
instanceRegion="$(ec2metadata --availability-zone | sed  s/.$//)"
nrLicenseKey=$(aws secretsmanager get-secret-value --secret-id sys/new-relic/config --query "SecretString" --output text | jq -r .NEW_RELIC_LICENSE)
nrConfigFile="/etc/newrelic-infra/logging.d/fluentbit.conf"
nrYmlFile="/etc/newrelic-infra/logging.d/fluentbit.yml"
nrPluginsFolder="/etc/newrelic-infra/plugins.d"
tdAgentBitConfig="/etc/td-agent-bit/td-agent-bit.conf"
tdAgentBitPlugins="/etc/td-agent-bit/plugins.conf"
instanceTags=$(aws ec2 --region "$instanceRegion" describe-tags --filters "Name=resource-id,Values=$instanceId" --output text)
validTagsValue=(Name Env Application)
newrelicsTagList=()

function check_service (){
    for service in ${servicesList[*]}
    do
        serviceStatus=$(systemctl list-unit-files | grep "$service" )
        if [ "$serviceStatus" == "" ]; then
                echo "$service not in the machine"
                install_service "$service"
        else
                echo "$service already installed"
        fi
    done
}

function install_service (){
    if [ "newrelic-infra" == "$1" ]; then
        echo "license_key: $nrLicenseKey" | sudo tee -a /etc/newrelic-infra.yml
        curl -sL https://download.newrelic.com/infrastructure_agent/gpg/newrelic-infra.gpg | sudo apt-key add -
        echo "deb [arch=amd64] https://download.newrelic.com/infrastructure_agent/linux/apt $osCodeName main" | sudo tee -a /etc/apt/sources.list.d/newrelic-infra.list
        apt -qq update
        apt -qq -o=Dpkg::Use-Pty=0 install newrelic-infra -y
        systemctl enable --now newrelic-infra
        # Retrive last release for td-agent-bit-plugin
        latestNewrelicPluginUrl=$(curl -s https://api.github.com/repos/newrelic/newrelic-fluent-bit-output/releases/latest | jq -r ".assets[] | select(.name | test(\"linux-amd64\")) | .browser_download_url")
        mkdir -p "$nrPluginsFolder"
        curl -sL "$latestNewrelicPluginUrl" -o $nrPluginsFolder/out_newrelic.so

    fi
    if [ "td-agent-bit" == "$1" ]; then
        curl -sL https://packages.fluentbit.io/fluentbit.key | sudo apt-key add -
        echo "deb https://packages.fluentbit.io/ubuntu/$osCodeName $osCodeName main" | sudo tee -a /etc/apt/sources.list.d/fluetbit.list
        apt -qq update
        apt -qq -o=Dpkg::Use-Pty=0 install td-agent-bit -y
        systemctl enable --now td-agent-bit
    fi
}

function manage_services (){
    for service in ${servicesList[*]}
    do
        systemctl "$1" "$service"
        echo "$service $1"
    done
}

function create_yml_file {
    cat >"$nrYmlFile" <<EOL
---
# Generataed from UserData
logs:
  - name: external-fluentbit-config-and-parsers-file
    fluentbit:
      config_file: /etc/td-agent-bit/td-agent-bit.conf
      parsers_file: /etc/td-agent-bit/parsers.conf
EOL
}

function create_td_agent_config {
    cat >"$tdAgentBitConfig" <<EOL
# Generataed from UserData
[SERVICE]
    flush        5
    daemon       Off
    log_level    info

    parsers_file parsers.conf
    plugins_file plugins.conf

@INCLUDE /etc/newrelic-infra/logging.d/fluentbit.conf
EOL
}

function create_td_agent_plugin {
    cat >"$tdAgentBitPlugins" <<EOL
# Generataed from UserData
[PLUGINS]
    Path ${nrPluginsFolder}/out_newrelic.so
EOL
}

function create_nr_configuration {
    # Prepare Tags for Newrelic Configuration
    for i in ${validTagsValue[*]}
    do
        newTag=$(echo "$instanceTags" | grep -w "$i" | awk '{print "'\''tag."$2"'\'' "$5}')
        if [ -n "$newTag" ]; then
            newrelicsTagList+=("$newTag")
        fi
    done

    newrelicsTagConfig=$(for i in ${newrelicsTagList[*]}; do echo "    Add $i"; done)

    cat >"$nrConfigFile" <<EOL
# Generataed from UserData
[INPUT]
    Name tail
    Path /var/log/syslog*
    Exclude_Path *.gz
    Buffer_Max_Size 24MB
    Buffer_Chunk_Size 1024k

[OUTPUT]
    Name newrelic
    Match *
    endpoint https://log-api.eu.newrelic.com/log/v1
    licenseKey ${nrLicenseKey}

[FILTER]
    Name modify
    Match *
${newrelicsTagConfig}
EOL
}

# Check if all services are installed and, if not, install them
check_service

# Stop all services
manage_services stop

# Make a backup copy of the configurations' files
for configFile in "$nrYmlFile" "$tdAgentBitConfig" "$tdAgentBitPlugins" "$nrConfigFile"
do
    if [ -f "$configFile" ]; then
        mv "$configFile" "$configFile.bck"
    fi
done

# Create new congiutations' files
create_yml_file
create_td_agent_config
create_td_agent_plugin
create_nr_configuration

# Start all services
manage_services start