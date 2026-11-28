import Testing
@testable import NoodleApp

private func checkShell(_ input: String, _ expected: [(ShellSyntax.Kind, String)]) {
    let tokens = ShellSyntax.tokenize(input)
    #expect(tokens.map(\.text).joined() == input)
    #expect(tokens.map(\.kind) == expected.map { $0.0 })
    #expect(tokens.map(\.text) == expected.map { $0.1 })
}

@Test func shellSyntaxHighlightsPromptCommandFlagsAndArguments() {
    checkShell("$ docker run --rm --name=dev alpine", [
        (.prompt, "$"), (.argument, " "), (.command, "docker"), (.argument, " "),
        (.argument, "run"), (.argument, " "), (.flag, "--rm"), (.argument, " "),
        (.flag, "--name=dev"), (.argument, " "), (.argument, "alpine"),
    ])
}

@Test func shellSyntaxPreservesQuotesAndHighlightsDoubleQuotedVariables() {
    checkShell("echo 'literal $HOME' \"hello $USER\"", [
        (.command, "echo"), (.argument, " "), (.string, "'literal $HOME'"),
        (.argument, " "), (.string, "\"hello "), (.variable, "$USER"), (.string, "\""),
    ])
}

@Test func shellSyntaxEscapesPreventSeparatorsCommentsAndExpansion() {
    checkShell(##"echo a\ b \| \# \$HOME "a\"b\$HOME""##, [
        (.command, "echo"), (.argument, " "), (.argument, #"a\ b"#),
        (.argument, " "), (.argument, #"\|"#), (.argument, " "), (.argument, ##"\#"##),
        (.argument, " "), (.argument, #"\$HOME"#), (.argument, " "),
        (.string, #""a\"b\$HOME""#),
    ])
}

@Test func shellSyntaxRestartsCommandAfterPipelineAndControlOperators() {
    checkShell("docker ps|cat && echo ok; pwd\nwhoami", [
        (.command, "docker"), (.argument, " "), (.argument, "ps"), (.operator, "|"),
        (.command, "cat"), (.argument, " "), (.operator, "&&"), (.argument, " "),
        (.command, "echo"), (.argument, " "), (.argument, "ok"), (.operator, ";"),
        (.argument, " "), (.command, "pwd"), (.argument, "\n"), (.command, "whoami"),
    ])
}

@Test func shellSyntaxAssignmentsLeaveCommandPositionOpen() {
    checkShell("FOO=bar BAR=\"$HOME\" docker run X=y", [
        (.argument, "FOO=bar"), (.argument, " "), (.argument, "BAR="),
        (.string, "\""), (.variable, "$HOME"), (.string, "\""), (.argument, " "),
        (.command, "docker"), (.argument, " "), (.argument, "run"),
        (.argument, " "), (.argument, "X=y"),
    ])
}

@Test func shellSyntaxCommentsStartOnlyAtWordBoundaries() {
    checkShell("echo foo#bar \"x\"#tail # comment | ignored\npwd", [
        (.command, "echo"), (.argument, " "), (.argument, "foo#bar"),
        (.argument, " "), (.string, "\"x\""), (.argument, "#tail"), (.argument, " "),
        (.comment, "# comment | ignored"), (.argument, "\n"), (.command, "pwd"),
    ])
}

@Test func shellSyntaxRecognizesVariablesAndFlagValues() {
    checkShell("echo $VAR ${HOME}/bin $? --path=$HOME", [
        (.command, "echo"), (.argument, " "), (.variable, "$VAR"), (.argument, " "),
        (.variable, "${HOME}"), (.argument, "/bin"), (.argument, " "),
        (.variable, "$?"), (.argument, " "), (.flag, "--path="), (.variable, "$HOME"),
    ])
}

@Test func shellSyntaxUnterminatedQuotesRemainLossless() {
    checkShell("echo \"open $HOME", [
        (.command, "echo"), (.argument, " "), (.string, "\"open "), (.variable, "$HOME"),
    ])
    checkShell("echo 'open\\", [
        (.command, "echo"), (.argument, " "), (.string, "'open\\"),
    ])
}

@Test func shellSyntaxWhitespaceAndEmptyInputAreLossless() {
    checkShell("", [])
    checkShell(" \t\n", [(.argument, " \t\n")])
    checkShell("echo café 👩🏽‍💻\t\n", [
        (.command, "echo"), (.argument, " "), (.argument, "café"), (.argument, " "),
        (.argument, "👩🏽‍💻"), (.argument, "\t\n"),
    ])
}

@Test func shellSyntaxRedirectionTargetsDoNotConsumeCommandPosition() {
    checkShell(">out FOO=1 docker ps 2>>errors | cat", [
        (.operator, ">"), (.argument, "out"), (.argument, " "), (.argument, "FOO=1"),
        (.argument, " "), (.command, "docker"), (.argument, " "), (.argument, "ps"),
        (.argument, " "), (.operator, "2>>"), (.argument, "errors"), (.argument, " "),
        (.operator, "|"), (.argument, " "), (.command, "cat"),
    ])
}

@Test func shellSyntaxContinuationDoesNotResetCommandPosition() {
    checkShell("docker \\\n  ps", [
        (.command, "docker"), (.argument, " "), (.argument, "\\\n"),
        (.argument, "  "), (.argument, "ps"),
    ])
}

@Test func shellSyntaxPromptRequiresLineStartAndDoesNotHideVariables() {
    checkShell("$HOME/bin/docker $ literal\n  $ pwd", [
        (.variable, "$HOME"), (.command, "/bin/docker"), (.argument, " "),
        (.argument, "$"), (.argument, " "), (.argument, "literal"),
        (.argument, "\n  "), (.prompt, "$"), (.argument, " "), (.command, "pwd"),
    ])
}

@Test func shellSyntaxQuotedFlagValuesRemainOneShellWord() {
    checkShell("docker --name=\"my dev\"#suffix -it", [
        (.command, "docker"), (.argument, " "), (.flag, "--name="),
        (.string, "\"my dev\""), (.flag, "#suffix"), (.argument, " "), (.flag, "-it"),
    ])
}

@Test func shellSyntaxEscapedAssignmentIsAnExecutableWord() {
    checkShell(#"FOO\=bar docker"#, [
        (.command, #"FOO\=bar"#), (.argument, " "), (.argument, "docker"),
    ])
}

@Test func shellSyntaxBoundaryCommentAfterOperatorKeepsNextCommand() {
    checkShell("echo ok;# comment\npwd", [
        (.command, "echo"), (.argument, " "), (.argument, "ok"), (.operator, ";"),
        (.comment, "# comment"), (.argument, "\n"), (.command, "pwd"),
    ])
}

@Test func shellSyntaxPreservesTrailingEscapesAndIncompleteExpansions() {
    checkShell("echo tail\\", [
        (.command, "echo"), (.argument, " "), (.argument, "tail\\"),
    ])
    checkShell("echo ${HOME", [
        (.command, "echo"), (.argument, " "), (.variable, "${HOME"),
    ])
    checkShell("echo \"\" ''", [
        (.command, "echo"), (.argument, " "), (.string, "\"\""),
        (.argument, " "), (.string, "''"),
    ])
}

@Test func shellSyntaxSubstitutionRestoresEnclosingCommand() {
    checkShell("echo $(pwd) tail", [
        (.command, "echo"), (.argument, " "), (.operator, "$("), (.command, "pwd"),
        (.operator, ")"), (.argument, " "), (.argument, "tail"),
    ])
}

@Test func shellSyntaxNestedSubstitutionsAndGroupsRestoreContext() {
    let input = "echo $(echo $(pwd); (whoami)) tail | cat"
    let tokens = ShellSyntax.tokenize(input)
    #expect(tokens.map(\.text).joined() == input)
    #expect(tokens.filter { $0.kind == .command }.map(\.text) == ["echo", "echo", "pwd", "whoami", "cat"])
    #expect(tokens.first { $0.text == "tail" }?.kind == .argument)
}

@Test func shellSyntaxSubstitutionKeepsAssignmentAndRedirectContext() {
    for input in ["ROOT=$(pwd) docker ps", ">$(echo out) docker ps", "ROOT=\"$(pwd)\" docker ps"] {
        let tokens = ShellSyntax.tokenize(input)
        #expect(tokens.map(\.text).joined() == input)
        #expect(tokens.filter { $0.kind == .command }.map(\.text) == [input.contains("echo") ? "echo" : "pwd", "docker"])
        #expect(tokens.last?.kind == .argument)
    }
}
