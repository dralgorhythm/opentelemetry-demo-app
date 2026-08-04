use serde::{Deserialize, Serialize};
use std::fs;
use std::net::SocketAddr;

fn default_redis_url() -> String {
    "redis://127.0.0.1:6379".to_string()
}

fn default_listen_address() -> String {
    "127.0.0.1:3000".to_string()
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Config {
    /// Redis URL to connect to
    #[serde(default = "default_redis_url")]
    pub redis_url: String,

    /// Address to listen on (as string for YAML compatibility)
    #[serde(default = "default_listen_address")]
    pub listen_address: String,
}

impl Config {
    pub fn load_from_file(path: &str) -> Result<Self, Box<dyn std::error::Error>> {
        match fs::read_to_string(path) {
            Ok(contents) => {
                let mut config: Config = serde_yaml::from_str(&contents)?;
                // Ensure we have defaults for any missing fields
                if config.redis_url.is_empty() {
                    config.redis_url = "redis://127.0.0.1:6379".to_string();
                }
                if config.listen_address.is_empty() {
                    config.listen_address = "127.0.0.1:3000".to_string();
                }
                Ok(config)
            }
            Err(e) => {
                tracing::error!("Error reading config file {}: {}", path, e);
                Err(Box::new(e))
            }
        }
    }

    pub fn listen_socket_addr(&self) -> Result<SocketAddr, Box<dyn std::error::Error>> {
        Ok(self.listen_address.parse()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_temp(name: &str, contents: &str) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("config-test-{}-{}", std::process::id(), name));
        fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn loads_full_config() {
        let path = write_temp(
            "full.yml",
            "redis_url: \"rediss://:token@example.internal:6379\"\nlisten_address: \"0.0.0.0:8080\"\n",
        );
        let config = Config::load_from_file(path.to_str().unwrap()).unwrap();
        assert_eq!(config.redis_url, "rediss://:token@example.internal:6379");
        assert_eq!(config.listen_address, "0.0.0.0:8080");
    }

    #[test]
    fn missing_fields_get_defaults() {
        let path = write_temp("empty-map.yml", "{}\n");
        let config = Config::load_from_file(path.to_str().unwrap()).unwrap();
        assert_eq!(config.redis_url, "redis://127.0.0.1:6379");
        assert_eq!(config.listen_address, "127.0.0.1:3000");
    }

    #[test]
    fn empty_strings_fall_back_to_defaults() {
        let path = write_temp(
            "empty-fields.yml",
            "redis_url: \"\"\nlisten_address: \"\"\n",
        );
        let config = Config::load_from_file(path.to_str().unwrap()).unwrap();
        assert_eq!(config.redis_url, "redis://127.0.0.1:6379");
        assert_eq!(config.listen_address, "127.0.0.1:3000");
    }

    #[test]
    fn missing_file_is_an_error() {
        assert!(Config::load_from_file("/nonexistent/config.yml").is_err());
    }

    #[test]
    fn socket_addr_parses_ip_and_port() {
        let config = Config {
            redis_url: String::new(),
            listen_address: "0.0.0.0:8080".to_string(),
        };
        assert_eq!(config.listen_socket_addr().unwrap().port(), 8080);
    }

    #[test]
    fn socket_addr_rejects_hostnames() {
        // listen_address is parsed as a literal SocketAddr — no DNS resolution.
        let config = Config {
            redis_url: String::new(),
            listen_address: "localhost:8080".to_string(),
        };
        assert!(config.listen_socket_addr().is_err());
    }
}
