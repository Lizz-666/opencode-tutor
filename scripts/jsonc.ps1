# Windows PowerShell 5.1 JSONC support. Preserve trivia and unchanged values during edits.
if (-not ('TutorJsonc' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
public static class TutorJsonc {
    class Node { public int Start,End; public string Kind,Key; public List<Node> Items=new List<Node>(); public int Comma=-1; }
    class Parser {
        public string Text; public int Pos;
        public Parser(string text) { Text=text; }
        void Skip() {
            while(Pos<Text.Length) {
                if(char.IsWhiteSpace(Text[Pos])||Text[Pos]=='\uFEFF') {Pos++;continue;}
                if(Pos+1<Text.Length && Text.Substring(Pos,2)=="//") {while(Pos<Text.Length && Text[Pos]!='\n')Pos++;continue;}
                if(Pos+1<Text.Length && Text.Substring(Pos,2)=="/*") {int e=Text.IndexOf("*/",Pos+2,StringComparison.Ordinal);if(e<0)throw new FormatException("Unclosed JSONC comment");Pos=e+2;continue;}
                break;
            }
        }
        string Str() {
            int begin=Pos++; bool escaped=false;
            while(Pos<Text.Length) {char c=Text[Pos++];if(c=='"'&&!escaped)return Text.Substring(begin,Pos-begin);if(c=='\\'&&!escaped)escaped=true;else escaped=false;}
            throw new FormatException("Unclosed JSON string");
        }
        public Node Value() {
            Skip();if(Pos>=Text.Length)throw new FormatException("Expected JSON value");
            Node n=new Node();n.Start=Pos;char c=Text[Pos];
            if(c=='{'||c=='[') {
                n.Kind=c=='{'?"object":"array";char close=c=='{'?'}':']';Pos++;Skip();
                while(Pos<Text.Length&&Text[Pos]!=close) {
                    int start=Pos;string key=null;
                    if(c=='{') {if(Text[Pos]!='"')throw new FormatException("Expected property");key=Str();Skip();if(Pos>=Text.Length||Text[Pos++]!=':')throw new FormatException("Expected colon");}
                    Node v=Value();if(key!=null){Node p=new Node();p.Kind="property";p.Key=key;p.Start=start;p.End=v.End;p.Items.Add(v);v=p;}
                    n.Items.Add(v);Skip();
                    if(Pos<Text.Length&&Text[Pos]==','){v.Comma=Pos++;Skip();continue;}
                    if(Pos>=Text.Length||Text[Pos]!=close)throw new FormatException("Expected comma");
                }
                if(Pos>=Text.Length)throw new FormatException("Unclosed JSON container");Pos++;
            } else if(c=='"') {n.Kind="scalar";Str();}
            else {n.Kind="scalar";while(Pos<Text.Length&&!char.IsWhiteSpace(Text[Pos])&&",]}".IndexOf(Text[Pos])<0&&Text[Pos]!='/')Pos++;if(Pos==n.Start)throw new FormatException("Invalid JSON value");}
            n.End=Pos;return n;
        }
        public Node Root() {Node n=Value();Skip();if(Pos!=Text.Length)throw new FormatException("Trailing JSON content");return n;}
    }
    static string Canon(string t, Node n) {
        if(n.Kind=="scalar")return t.Substring(n.Start,n.End-n.Start);
        var a=new List<string>();foreach(Node i in n.Items)a.Add(n.Kind=="object"?i.Key+":"+Canon(t,i.Items[0]):Canon(t,i));
        return (n.Kind=="object"?"{":"[")+string.Join(",",a.ToArray())+(n.Kind=="object"?"}":"]");
    }
    public static string Clean(string text) {return Canon(text,new Parser(text).Root());}
    // Decode property names through a small JSON string decoder so escaped names compare correctly.
    static string Key(string value) {
        var b=new StringBuilder();for(int i=1;i<value.Length-1;i++){char c=value[i];if(c!='\\'){b.Append(c);continue;}c=value[++i];switch(c){case 'u':b.Append((char)Convert.ToInt32(value.Substring(i+1,4),16));i+=4;break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;default:b.Append(c);break;}}return b.ToString();
    }
    class Edit {public int Start,End;public string Text;}
    static string Apply(string s,List<Edit> edits) {edits.Sort((a,b)=>b.Start.CompareTo(a.Start));foreach(Edit e in edits)s=s.Substring(0,e.Start)+e.Text+s.Substring(e.End);return s;}
    static string PatchArray(string old,Node a,string next,Node b) {
        int n=a.Items.Count,m=b.Items.Count;
        var left=new string[n];var right=new string[m];
        for(int i=0;i<n;i++)left[i]=Canon(old,a.Items[i]);
        for(int j=0;j<m;j++)right[j]=Canon(next,b.Items[j]);
        // Align in order: keep matching entries, patch replacements in place, and
        // insert/delete at their actual positions instead of appending changes.
        var cost=new int[n+1,m+1];
        for(int i=n;i>=0;i--)for(int j=m;j>=0;j--) {
            if(i==n)cost[i,j]=m-j;
            else if(j==m)cost[i,j]=n-i;
            else cost[i,j]=Math.Min(cost[i+1,j+1]+(left[i]==right[j]?0:1),Math.Min(cost[i+1,j]+1,cost[i,j+1]+1));
        }
        var text=new StringBuilder("[");int x=0,y=0,cursor=a.Start+1;
        while(x<n||y<m) {
            if(x<n&&y<m&&cost[x,y]==cost[x+1,y+1]+(left[x]==right[y]?0:1)) {
                Node item=a.Items[x++];Node target=b.Items[y++];
                text.Append(old.Substring(cursor,item.Start-cursor));
                text.Append(PatchNode(old,item,next,target));
                if(item.Comma>=0)text.Append(old.Substring(item.End,item.Comma-item.End));
                if(item.Comma>=0||y<m)text.Append(',');
                cursor=item.Comma>=0?item.Comma+1:item.End;
            } else if(x<n&&cost[x,y]==cost[x+1,y]+1) {
                Node item=a.Items[x++];
                text.Append(old.Substring(cursor,item.Start-cursor));
                if(item.Comma>=0)text.Append(old.Substring(item.End,item.Comma-item.End));
                cursor=item.Comma>=0?item.Comma+1:item.End;
            } else {
                Node item=b.Items[y++];
                text.Append("\n  ");text.Append(next.Substring(item.Start,item.End-item.Start));text.Append(',');
            }
        }
        text.Append(old.Substring(cursor,a.End-cursor));
        return text.ToString();
    }
    static bool SameValue(string left,Node a,string right,Node b) {
        if(a.Kind!=b.Kind||a.Items.Count!=b.Items.Count)return false;
        if(a.Kind=="scalar")return Canon(left,a)==Canon(right,b);
        if(a.Kind=="array") {
            for(int i=0;i<a.Items.Count;i++)if(!SameValue(left,a.Items[i],right,b.Items[i]))return false;
        } else {
            var target=new Dictionary<string,Node>();foreach(Node item in b.Items)target.Add(Key(item.Key),item.Items[0]);
            foreach(Node item in a.Items) {Node other;string key=Key(item.Key);
                if(!target.TryGetValue(key,out other)||!SameValue(left,item.Items[0],right,other))return false;
                target.Remove(key);
            }
        }
        return true;
    }
    public static bool Equivalent(string left,string right) {
        return SameValue(left,new Parser(left).Root(),right,new Parser(right).Root());
    }
    static string PatchNode(string old,Node a,string next,Node b) {
        string segment=old.Substring(a.Start,a.End-a.Start);
        if(Canon(old,a)==Canon(next,b))return segment;
        if(a.Kind!=b.Kind||a.Kind=="scalar")return next.Substring(b.Start,b.End-b.Start);
        if(a.Kind=="array")return PatchArray(old,a,next,b);
        var edits=new List<Edit>();var additions=new List<Node>();
        if(a.Kind=="object") {
            var target=new Dictionary<string,Node>();foreach(Node i in b.Items){string k=Key(i.Key);if(target.ContainsKey(k))throw new FormatException("Duplicate property");target.Add(k,i);}
            var seen=new HashSet<string>();
            foreach(Node i in a.Items){string k=Key(i.Key);if(!seen.Add(k))throw new FormatException("Duplicate property");Node other;
                if(target.TryGetValue(k,out other)){edits.Add(new Edit{Start=i.Items[0].Start-a.Start,End=i.End-a.Start,Text=PatchNode(old,i.Items[0],next,other.Items[0])});target.Remove(k);}
                else edits.Add(new Edit{Start=i.Start-a.Start,End=(i.Comma>=0?i.Comma+1:i.End)-a.Start,Text=""});
            }
            foreach(Node i in b.Items)if(target.ContainsKey(Key(i.Key)))additions.Add(i);
        }
        segment=Apply(segment,edits);
        if(additions.Count>0){Node current=new Parser(segment).Root();bool comma=current.Items.Count>0&&current.Items[current.Items.Count-1].Comma<0;
            var text=new StringBuilder(comma?",":"");foreach(Node add in additions){text.Append("\n  ");text.Append(next.Substring(add.Start,add.End-add.Start));text.Append(',');}text.Append('\n');
            segment=segment.Insert(current.End-1,text.ToString());}
        return segment;
    }
    public static string Patch(string original,string desired) {
        Node a=new Parser(original).Root();Node b=new Parser(desired).Root();
        string patched=PatchNode(original,a,desired,b);
        if(!SameValue(patched,new Parser(patched).Root(),desired,b))throw new FormatException("JSONC edit changed the requested value or array order");
        return original.Substring(0,a.Start)+patched+original.Substring(a.End);
    }
}
'@
}

function ConvertFrom-TutorJsonc {
    param([string]$Text)
    $clean = [TutorJsonc]::Clean($Text)
    return (ConvertFrom-Json -InputObject $clean -ErrorAction Stop)
}

function Write-TutorJsonc {
    param([string]$Path, $Value, [switch]$IsArray)
    $desired = ConvertTo-Json -InputObject $Value -Depth 30
    if (Test-Path -LiteralPath $Path) {
        $original = [IO.File]::ReadAllText($Path)
        if (-not [string]::IsNullOrWhiteSpace($original)) { $desired = [TutorJsonc]::Patch($original, $desired) }
    }
    # Validate before committing; malformed input never gets overwritten.
    $null = ConvertFrom-TutorJsonc -Text $desired
    $tmp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, $desired, (New-Object Text.UTF8Encoding $true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
