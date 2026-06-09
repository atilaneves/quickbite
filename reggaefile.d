import reggae;

alias ut = dubBuild!(Configuration("unittest"));
alias utCov = dubBuild!(
    Configuration("unittest-cov"),
    CompilerFlags("-unittest -cov"),
);
alias bench = dubBuild!(Configuration("benchmark"));
alias qb = dubBuild!(Configuration("qb"));

mixin build!(
    ut,
    utCov,
    bench,
    qb,
);
