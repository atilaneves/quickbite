import reggae;

alias ut = dubBuild!(Configuration("unittest"));
alias utCov = dubBuild!(
    Configuration("unittest-cov"),
    CompilerFlags("-unittest -cov"),
);
// the flags mirror dub's `benchmark-opt` build type
alias bench = dubBuild!(
    Configuration("benchmark"),
    CompilerFlags("-O -release -boundscheck=off"),
);
alias qb = dubBuild!(Configuration("qb"));

mixin build!(
    ut,
    utCov,
    bench,
    qb,
);
