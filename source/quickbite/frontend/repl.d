module quickbite.frontend.repl;

private:

public enum ReplCellKind {
    incomplete,
    noDisplay,
    expression,
    typeExpression,
}

public struct ReplCell {
    public ReplCellKind kind;
    public string source;
    public imported!"quickbite.frontend.cell".Cell evalCell;
}

public struct ReplSession {
    private imported!"quickbite.frontend.cell".EvalSession evalSession;

    public this(in string[] importPaths) {
        evalSession = typeof(evalSession)(importPaths);
    }

    public ReplCell submit(in string input) {
        if (evalSession.isTypeExpressionCell(input)) {
            auto cell = evalSession.submit(input ~ ".stringof");
            return ReplCell(ReplCellKind.typeExpression, cell.source, cell);
        }

        auto cell = evalSession.submit(input);
        return ReplCell(replCellKind(cell.kind), cell.source, cell);
    }

    public void accept(in ReplCell cell) {
        if (cell.kind != ReplCellKind.typeExpression)
            evalSession.accept(cell.evalCell);
    }

    public void loadModuleSource(in string source) {
        evalSession.loadModuleSource(source);
    }

    public void loadModuleFile(in string filePath, in string source) {
        evalSession.loadModuleFile(filePath, source);
    }

    public string loadedModuleSource() const @safe pure {
        return evalSession.loadedModuleSource;
    }
}

private ReplCellKind replCellKind(
    in imported!"quickbite.frontend.cell".Cell.Kind kind,
) @safe pure {
    import quickbite.frontend.cell: Cell;

    final switch (kind) with (Cell.Kind) {
        case incomplete:
            return ReplCellKind.incomplete;
        case noDisplay:
            return ReplCellKind.noDisplay;
        case expression:
            return ReplCellKind.expression;
    }
}
