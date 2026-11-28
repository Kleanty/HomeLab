namespace HomeLab.Agent;

public sealed class ControlDeckConfig
{
    public List<DeckAction> Actions { get; set; } = [];
}

/// <summary>Computer-side bindings. Only Id/Label/Kind are sent to a phone.</summary>
public sealed class DeckAction
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Kind { get; set; } = "shortcut";
    public string Target { get; set; } = "";
    public string? Argument { get; set; }
    public int Value { get; set; }
    public string? Device { get; set; }
    public string? Icon { get; set; }
    public bool Enabled { get; set; } = true;
}
public sealed record DeckItem(string Id, string Name, string Kind, string? State = null, bool Available = true);
public sealed record DeckResult(bool Ok, string? Error = null);
