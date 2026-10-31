package config

import (
	"fmt"
	"net"
	"os"
	"slices"
	"strconv"

	"github.com/joho/godotenv"
)

const (
	AppEnvProduction = "production"
	AppEnvDevelopment = "development"
)

type Config struct {
	AppEnv       AppEnvConfig
	ServerConfig ServerConfig
}

func (c *Config) Validate() error {
	if !slices.Contains([]string{AppEnvProduction, AppEnvDevelopment}, c.AppEnv.Value) {
		return fmt.Errorf("invalid APP_ENV: '%s'", c.AppEnv.Value)
	}

	if ip := net.ParseIP(c.ServerConfig.Host); ip == nil {
		return fmt.Errorf("invalid SERVER_HOST: '%s'", c.ServerConfig.Host)
	}

	if p, err := strconv.Atoi(c.ServerConfig.Port); err != nil || p < 1 || p > 65535 {
		return fmt.Errorf("invalid SERVER_PORT: '%s'", c.ServerConfig.Port)
	}

	return nil
}

type AppEnvConfig struct {
	Value string
}

func (a *AppEnvConfig) IsProduction() bool  { return a.Value == AppEnvProduction }
func (a *AppEnvConfig) IsDevelopment() bool { return a.Value == AppEnvDevelopment }

type ServerConfig struct {
	Host string
	Port string
}

func Load() *Config {
	err := godotenv.Overload(".env")
	if err != nil {
		panic("Can't load .env file.")
	}

	c := &Config{
		AppEnv: AppEnvConfig{
			Value: getEnv("MEDIA_VAULT_APP", AppEnvProduction),
		},
		ServerConfig: ServerConfig{
			Host: getEnv("MEDIA_VAULT_SERVER_HOST", "127.0.0.1"),
			Port: getEnv("MEDIA_VAULT_SERVER_PORT", "8080"),
		},
	}

	if err := c.Validate(); err != nil {
		panic(err)
	}

	return c
}

func getEnv(k, d string) string {
	if value, exists := os.LookupEnv(k); exists {
		return value
	}

	return d
}
