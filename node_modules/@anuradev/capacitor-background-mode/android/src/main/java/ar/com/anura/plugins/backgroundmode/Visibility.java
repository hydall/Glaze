package ar.com.anura.plugins.backgroundmode;

import java.util.HashMap;
import java.util.Map;

public enum Visibility {
    PUBLIC("public"),
    PRIVATE("private"),
    SECRET("secret");

    public final String label;

    private static final Map<String, Visibility> BY_LABEL = new HashMap<>();

    static {
        for (Visibility e : values()) {
            BY_LABEL.put(e.label, e);
        }
    }

    Visibility(String label) {
        this.label = label;
    }

    public static Visibility valueOfLabel(String label) {
        return BY_LABEL.get(label);
    }
}
