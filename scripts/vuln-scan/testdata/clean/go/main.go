// Command fixture imports a module version with known vulnerabilities but
// never calls the vulnerable functions, so govulncheck reports nothing.
package main

import (
	"fmt"

	"golang.org/x/text/width"
)

func main() {
	fmt.Println(width.Narrow.String("ｈｅｌｌｏ"))
}
