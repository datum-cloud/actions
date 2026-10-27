// Command fixture calls a function with a known vulnerability so that
// govulncheck reports it as reachable.
package main

import (
	"fmt"

	"golang.org/x/text/language"
)

func main() {
	tags, _, err := language.ParseAcceptLanguage("en-US,en;q=0.9")
	fmt.Println(tags, err)
}
