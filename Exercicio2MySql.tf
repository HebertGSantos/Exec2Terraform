terraform {
    required_version = ">= 0.10"
    
    required_providers {
        azurerm = {
        source  = "hashicorp/azurerm"
        version = ">= 2.46.0"
        }
    }    
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "exec-mysql" {
  name     = "exec-rg-mysql"
  location = "West Europe"
}

resource "azurerm_virtual_network" "exec-vn-mysql" {
  name                = "virtualNetwork1"
  location            = azurerm_resource_group.exec-mysql.location
  resource_group_name = azurerm_resource_group.exec-mysql.name
  address_space       = ["10.0.0.0/16"]
  
} 

resource "azurerm_subnet" "exec-sb-mysql" {
    name                 = "exec-sbmysql"
    resource_group_name  = azurerm_resource_group.exec-mysql.name
    virtual_network_name = azurerm_virtual_network.exec-vn-mysql.name
    address_prefixes       = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "exec-pl-ip-mysql" {
    name                         = "exec-plipmysql"
    location                     = azurerm_resource_group.exec-mysql.location
    resource_group_name          = azurerm_resource_group.exec-mysql.name
    allocation_method            = "Static"
}

resource "azurerm_network_security_group" "exec-nsg-mysql" {
    name                = "exec-nsgmysql"
    location            = azurerm_resource_group.exec-mysql.location
    resource_group_name = azurerm_resource_group.exec-mysql.name

    security_rule {
        name                       = "mysql"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "SSH"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface" "exec-nti-mysql" {
    name                      = "exec-ntimysql"
    location                  = azurerm_resource_group.exec-mysql.location
    resource_group_name       = azurerm_resource_group.exec-mysql.name

    ip_configuration {
        name                          = "myNicConfiguration"
        subnet_id                     = azurerm_subnet.exec-sb-mysql.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.exec-pl-ip-mysql.id
    }
}
resource "azurerm_network_interface_security_group_association" "exec-nisg-mysql" {
    network_interface_id      = azurerm_network_interface.exec-nti-mysql.id
    network_security_group_id = azurerm_network_security_group.exec-nsg-mysql.id
}

data "azurerm_public_ip" "exec-ip-data_db-mysql" {
  name                = azurerm_public_ip.exec-pl-ip-mysql.name
  resource_group_name = azurerm_resource_group.exec-mysql.name
}

resource "azurerm_storage_account" "exec-st-ac-mysql" {
    name                        = "execstacmysql"
    resource_group_name         = azurerm_resource_group.exec-mysql.name
    location                    = azurerm_resource_group.exec-mysql.location
    account_tier                = "Standard"
    account_replication_type    = "LRS"
}

resource "azurerm_linux_virtual_machine" "exec-lvm-mysql" {
    name                  = "exec-lvm-mysql"
    location              = azurerm_resource_group.exec-mysql.location
    resource_group_name   = azurerm_resource_group.exec-mysql.name
    network_interface_ids = [azurerm_network_interface.exec-nti-mysql.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "myOsDiskMySQL"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "myvm"
    admin_username = "testadmin"
    admin_password = "Password1234!"
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.exec-st-ac-mysql.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.exec-mysql ]
}

output "public_ip_address_mysql" {
    value = azurerm_public_ip.exec-pl-ip-mysql.ip_address
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.exec-lvm-mysql]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = "testadmin"
            password = "Password1234!"
            host = data.azurerm_public_ip.exec-ip-data_db-mysql.ip_address
            agent    = "false"
        }
        source = "config"
        destination = "/home/azureuser"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = "testadmin"
            password = "Password1234!"
            host = data.azurerm_public_ip.exec-ip-data_db-mysql.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/azureuser/config/user.sql",
            "sudo cp -f /home/azureuser/config/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}