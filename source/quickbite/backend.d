module quickbite.backend;

private:

public interface Backend {
    public imported!"quickbite.lang".Value eval(in string expr);

    public void runTests(in string moduleSource);
}
