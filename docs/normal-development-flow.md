# Normal Development Lifecycle Flow

This diagram illustrates the complete normal development lifecycle from production release through feature development to the next release.

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'primaryColor': '#2A9D8F', 'primaryTextColor': '#ffffff', 'primaryBorderColor': '#2A9D8F', 'lineColor': '#333333', 'secondaryColor': '#E76F51', 'tertiaryColor': '#F4A261', 'background': '#ffffff', 'mainBkg': '#ffffff'}, 'flowchart': {'nodeSpacing': 50, 'rankSpacing': 60}}}%%
flowchart TD
    Start([Production Tag Created<br/>v2.11.0]) --> ProdWorkflow[🤖 Production Workflow Triggers<br/>Deploy + Bump main to 2.12.0]
    ProdWorkflow --> NewCycle[📍 Main becomes starting point<br/>for next development cycle]
    
    NewCycle --> CutNewRC[🔧 Engineer runs:<br/>./cut_rc.sh --version 2.12.0 --replace]
    CutNewRC --> FirstRC[✅ Creates: release/2.12.0-rc.0<br/>First staging snapshot]
    FirstRC --> DevStarts[✅ Development begins:<br/>Feature branches from main]
    
    DevStarts --> FeatureBranch[👥 Engineers create:<br/>feature/EN-1234-cool-thing]
    FeatureBranch --> PR[📝 Work flows through:<br/>PRs back to main]
    PR --> Merge[✅ PR Merged to main]
    
    Merge --> StagingTrigger[🔄 Main merge triggers staging]
    StagingTrigger --> ContinueRC[🔧 Continue RC train:<br/>./cut_rc.sh --replace]
    ContinueRC --> NextRC[📦 Creates: release/2.12.0-rc.N<br/>rc.0 → rc.1 → rc.2...]
    NextRC --> StagingDeploy[🧪 RC deployment tests<br/>cumulative changes]
    
    StagingDeploy --> MoreDev{More development<br/>needed?}
    MoreDev -->|Yes| FeatureBranch
    MoreDev -->|No| ReadyForProd[✅ Latest RC contains<br/>all merged features<br/>e.g., release/2.12.0-rc.8]
    
    ReadyForProd --> Promote[🚀 Engineer promotes:<br/>./promote_rc.sh<br/>or ./promote_rc.sh --auto-next-rc]
    Promote --> ProdTag[✅ Creates: v2.12.0 tag<br/>🆕 Auto-creates next RC train (if --auto-next-rc)]
    ProdTag --> CycleRepeat[🔄 Cycle repeats<br/>Back to step 1 with 2.13.0]
    CycleRepeat --> Start
    
    %% Styling
    classDef prodNode fill:#2A9D8F,stroke:#264653,stroke-width:2px,color:#ffffff
    classDef scriptNode fill:#E76F51,stroke:#C1440E,stroke-width:2px,color:#ffffff
    classDef processNode fill:#F4A261,stroke:#E09F3E,stroke-width:2px,color:#000000
    classDef decisionNode fill:#9B59B6,stroke:#7D3C98,stroke-width:2px,color:#ffffff
    classDef startEndNode fill:#264653,stroke:#1A1A1A,stroke-width:3px,color:#ffffff
    
    class Start,CycleRepeat startEndNode
    class ProdWorkflow,ProdTag,FirstRC,NextRC,StagingDeploy prodNode
    class CutNewRC,ContinueRC,Promote scriptNode
    class NewCycle,DevStarts,FeatureBranch,PR,Merge,StagingTrigger,ReadyForProd processNode
    class MoreDev decisionNode
```

## Key Characteristics of Normal Development:

### 🔄 **Linear Progression**
- Each development cycle builds on the previous production release
- Version numbers follow predictable semantic versioning (2.11.0 → 2.12.0 → 2.13.0)
- Main branch is always the starting point for new features

### 🚂 **RC Train Pattern**
- **rc.0**: Initial staging snapshot (may have minimal changes)
- **rc.1, rc.2, rc.3...**: Progressive iterations with accumulated features
- **rc.N**: Final candidate containing all features for the release

### 👥 **Collaborative Flow**
- Multiple engineers work on separate feature branches
- All work flows through main via pull requests
- Each main merge advances the RC train automatically
- Staging continuously tests the evolving feature set

### 🎯 **Predictable Releases**
- Clear decision point: "Is the latest RC ready for production?"
- All stakeholders can see what's included in upcoming release
- Version bumping happens at predictable cycle boundaries
- No surprises about what's being released when

### 🚀 **Streamlined Promotion** (New)
- **Standard workflow**: `promote_rc.sh` creates production tag, manual next RC creation
- **Automated workflow**: `promote_rc.sh --auto-next-rc` handles promotion + next RC train automatically
- **Eliminates gaps**: No more forgetting to checkout main and create the next development cycle
- **Seamless transitions**: From promotion completion directly to next development ready state