MODULE_DIR := vault
BIN_DIR := bin

VERSION=0.0.1

LDFLAGS := -X '$(MODULE_DIR)/internal/internal.Version=$(VERSION)'

install:
	@echo "Installing golangci-lint (v1.64.6)..."
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.64.6

build:
	@echo "Compiling for linux, windows and macOS..."
	@mkdir -p $(BIN_DIR)

	GOOS=linux 		GOARCH=arm64 	go build -o $(BIN_DIR)/vaultd-linux-arm 			$(MODULE_DIR)/cmd/vaultd/main.go	
	GOOS=linux 		GOARCH=amd64 	go build -o $(BIN_DIR)/vaultd-linux-amd64			$(MODULE_DIR)/cmd/vaultd/main.go	

	GOOS=windows 	GOARCH=arm64 	go build -o $(BIN_DIR)/vaultd-windows-arm.exe 		$(MODULE_DIR)/cmd/vaultd/main.go	
	GOOS=windows 	GOARCH=amd64 	go build -o $(BIN_DIR)/vaultd-windows-amd64.exe		$(MODULE_DIR)/cmd/vaultd/main.go	

	GOOS=darwin 	GOARCH=arm64 	go build -o $(BIN_DIR)/vaultd-mac-arm 				$(MODULE_DIR)/cmd/vaultd/main.go	
	GOOS=darwin 	GOARCH=amd64 	go build -o $(BIN_DIR)/vaultd-mac-amd64				$(MODULE_DIR)/cmd/vaultd/main.go

run:
	vault/cmd/vault/main.go	

lint:
	@echo "Running go lint"
	cd $(MODULE_DIR) && golangci-lint run

format:
	@echo "Formating the code with applied code simplification and write instead returning just result..."
	gofmt -s -w ./vault

vet:
	@echo "Analyzing the code using go vet..."
	cd $(MODULE_DIR) && go vet ./...

test:
	@echo "Running go tests with detailed output and race condition detections."
	cd $(MODULE_DIR) && go test ./...

migrate:
	@echo "Not implemented"

clean:
	@echo "Removing compiled files."
	rm -rf $(BIN_DIR)