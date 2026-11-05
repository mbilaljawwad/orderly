# running the application
run: 
	go run cmd/main.go

# test the application
test:
	go test ./... -v

# linting the application
lint:
	golangci-lint run