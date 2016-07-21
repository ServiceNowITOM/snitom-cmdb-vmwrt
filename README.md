# Real-Time CMDB for VMware

The Real-Time CMDB for VMware provides a [Perl](https://www.perl.org/) based [Docker](https://www.docker.com/) image that collects real-time updates from the VMware vSphere API and then updates a ServiceNow CMDB instance, in effect providing timely CMDB accuracy for VMware inventory objects.

## Prerequisites

* ServiceNow instance with the VMware plugin, Geneva+
* VMware vCenter, version 4.1+
* Docker

## Installation

### ServiceNow Update Set

The ServiceNow [update set](https://raw.githubusercontent.com/ServiceNowITOM/snitom-cmdb-vmwrt/master/snitom-cmdb-vmwrt.xml) provides a scripted REST interface and  script include used to receive and process updates from the collector agent.

1. [Import](https://docs.servicenow.com/bundle/helsinki-application-development/page/c2/t_LoadCustomizationsFromAnXMLFile-Up.html) update set.
2. [Commit](https://docs.servicenow.com/bundle/helsinki-application-development/page/build/system-update-sets/task/t_CommitAnUpdateSet.html) update set.
3. (Optional) Create a [user](https://docs.servicenow.com/bundle/helsinki-servicenow-platform/page/administer/users-and-groups/task/t_CreateAUser.html) on the ServiceNow instance.  Alternatively, use an existing user credential from your ServiceNow instance.

### Docker Collector Agent

The Docker collection agent runs a Perl process that connects and monitors the VMware vCenter API for update notifications.  The agent configuration, including username and passwords for VMware and ServiceNow, are defined in a configuration file *vmwrt.json*.  The template configuration file can be found [here](https://raw.githubusercontent.com/ServiceNowITOM/snitom-cmdb-vmwrt/master/vmwrt.json.template).

1. Download [vmwrt.json.template](https://raw.githubusercontent.com/ServiceNowITOM/snitom-cmdb-vmwrt/master/vmwrt.json.template) to your Docker host.
2. Rename **vmwrt.json.template** to **vmwrt.json**.
3. Modify **vmwrt.json**.  Specifically the **host**, **user**, and **pass** properties for both **servicenow** and **vmware**.
4. Run Docker collection agent.  Specify the parent directory that contains the vmwrt.json file.
5. Verify Docker collection agent is running.

```json
{
	"servicenow": {
		"host": "your-instance.service-now.com",
		"user": "instance.username",
		"pass": "instance.userpass",
		"path": "/api/snc/vmwrt_cmdb"
	},
	"vmware": {
		"host": "vcenter.localdomain",
		"user": "vc.username",
		"pass": "vc.userpass"
	},
	...
}
```
```
docker run -d --name vmwrt -v ~/vmwrt/etc:/opt/vmwrt/etc snitom/vmwrt:latest
docker logs -f vmwrt
```

## Limitations

This project was built primarily to illustrate the concept of real-time updates leveraging VMware's PropertyCollector API model.  Currently, it is fairly limited in the amount of data collected.  It also does not implement CMDB CI relationships in ServiceNow, so it cannot replace standard cloud discovery schedules.

Functionality that can be validated:
* Object delete, create, rename
* Synchronization of CMDB with current VMware inventory on collector startup
* Shallow properties such as cluster usable resources

Feel free to identify any enhancements that would be useful, the intent of this is to demonstrate capability that can be driven into the core engineering of ServiceNow and to continue to expand the capabilities to enhance cloud discovery.

## Authors

- [**Reuben Stump**](https://github.com/stumpr)

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE) file for details

## Acknowledgments

* Hat tip to anyone who's code was used
* Inspiration
* etc