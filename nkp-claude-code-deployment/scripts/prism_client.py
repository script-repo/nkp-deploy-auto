import dataclasses
import json
from typing import Any, Dict, List, Optional

import requests


@dataclasses.dataclass
class PrismCentralCredentials:
    host: str
    username: str
    password: str
    verify_ssl: bool = False


class PrismCentralClient:
    """Minimal Prism Central v3 API helper for discovery operations."""

    def __init__(self, credentials: PrismCentralCredentials) -> None:
        self.credentials = credentials
        self.base_url = f"https://{credentials.host}:9440/api/nutanix/v3"
        self.session = requests.Session()
        self.session.auth = (credentials.username, credentials.password)
        self.session.verify = credentials.verify_ssl
        self.session.headers.update({"Content-Type": "application/json"})

    def _post(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{self.base_url}/{path}"
        response = self.session.post(url, data=json.dumps(payload), timeout=30)
        response.raise_for_status()
        return response.json()

    def verify(self) -> Dict[str, Any]:
        return {
            "clusters": self.list_clusters(),
            "subnets": self.list_subnets(),
            "storage_containers": self.list_storage_containers(),
            "projects": self.list_projects(),
        }

    def list_clusters(self) -> List[Dict[str, Any]]:
        payload = {"kind": "cluster", "offset": 0, "length": 50}
        data = self._post("clusters/list", payload)
        return [self._transform_cluster(entity) for entity in data.get("entities", [])]

    def _transform_cluster(self, entity: Dict[str, Any]) -> Dict[str, Any]:
        metadata = entity.get("metadata", {})
        status = entity.get("status", {})
        resources = status.get("resources", {})
        return {
            "name": metadata.get("name", "unknown-cluster"),
            "uuid": metadata.get("uuid"),
            "nodes": resources.get("nodes", []),
            "network": resources.get("network", {}),
        }

    def list_subnets(self) -> List[Dict[str, Any]]:
        payload = {"kind": "subnet", "offset": 0, "length": 100}
        data = self._post("subnets/list", payload)
        return [self._transform_subnet(entity) for entity in data.get("entities", [])]

    def _transform_subnet(self, entity: Dict[str, Any]) -> Dict[str, Any]:
        metadata = entity.get("metadata", {})
        status = entity.get("status", {})
        resources = status.get("resources", {})
        subnet_type = resources.get("subnet_type", "")
        return {
            "name": metadata.get("name"),
            "uuid": metadata.get("uuid"),
            "vlan_id": resources.get("vlan_id"),
            "subnet_type": subnet_type,
            "ip_config": resources.get("ip_config", {}),
        }

    def list_storage_containers(self) -> List[Dict[str, Any]]:
        payload = {"kind": "storage_container", "offset": 0, "length": 50}
        data = self._post("storage_containers/list", payload)
        return [self._transform_container(entity) for entity in data.get("entities", [])]

    def _transform_container(self, entity: Dict[str, Any]) -> Dict[str, Any]:
        metadata = entity.get("metadata", {})
        status = entity.get("status", {})
        resources = status.get("resources", {})
        return {
            "name": metadata.get("name"),
            "uuid": metadata.get("uuid"),
            "replication_factor": resources.get("replication_factor"),
            "max_capacity": resources.get("max_capacity"),
        }

    def list_projects(self) -> List[Dict[str, Any]]:
        payload = {"kind": "project", "offset": 0, "length": 50}
        data = self._post("projects/list", payload)
        return [self._transform_project(entity) for entity in data.get("entities", [])]

    def _transform_project(self, entity: Dict[str, Any]) -> Dict[str, Any]:
        metadata = entity.get("metadata", {})
        return {
            "name": metadata.get("name"),
            "uuid": metadata.get("uuid"),
        }


def gather_inventory(
    host: str,
    username: str,
    password: str,
    verify_ssl: Optional[bool] = False,
) -> Dict[str, Any]:
    credentials = PrismCentralCredentials(
        host=host, username=username, password=password, verify_ssl=verify_ssl or False
    )
    client = PrismCentralClient(credentials)
    return client.verify()
