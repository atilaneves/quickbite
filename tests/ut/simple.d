import quickbite;
import ut;


@("simple")
unittest {
    with(immutable Sandbox()) {
        write(
            "test.d",
            q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }
        )
    }
}
