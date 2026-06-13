module ut.backends.runner.rt.llvm_jit;


import ut.backends;


// Step 1 gate proof: LLVMJit runs a passing fixture, and on a failing fixture
// its Throwable is caught with a message that byte-matches SystemLinker's for
// the same fixture. The byte-match is the proof the JIT'd .eh_frame is
// registered and unwinding through JIT'd frames works. Runtime values (a
// mutable local) keep DMD from constant-folding the assert before codegen.

enum passingFixture = q{
    int twice(int x) {
        return x * 2;
    }

    unittest {
        int n = 21;
        assert(twice(n) == 42);
    }
};

enum failingFixture = q{
    int twice(int x) {
        return x * 2;
    }

    unittest {
        int n = 21;
        assert(twice(n) == 41);
    }
};


@("LLVMJit.passingFixtureRuns")
@Tags("LLVMJit")
unittest {
    runBackendSourceFixtureTests!LLVMJit(passingFixture);
}

@("LLVMJit.failingFixtureMessageMatchesSystemLinker")
@Tags("LLVMJit")
unittest {
    const jitResults = runBackendSourceFixtureTestResults!LLVMJit(failingFixture);
    const linkerResults = runBackendSourceFixtureTestResults!SystemLinker(failingFixture);

    jitResults.length.should == 1;
    linkerResults.length.should == 1;
    jitResults[0].passed.should == false;
    linkerResults[0].passed.should == false;
    // The eh_frame/unwinding gate: same Throwable message, byte for byte.
    jitResults[0].message.should == linkerResults[0].message;
}

// Evidence for the report: a non-allocating assert (static-string message)
// unwinds out of JIT'd code into the host catch with the SystemLinker message.
@("LLVMJit.ehFrameProofNonAllocatingAssert")
@Tags("LLVMJit")
unittest {
    enum fix = q{
        void boom() { assert(0); }
        unittest { boom; }
    };
    const jit = runBackendSourceFixtureTestResults!LLVMJit(fix);
    const sys = runBackendSourceFixtureTestResults!SystemLinker(fix);
    jit[0].passed.should == false;
    jit[0].message.should == sys[0].message;
}
