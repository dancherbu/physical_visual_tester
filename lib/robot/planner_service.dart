import 'dart:convert';
import '../spikes/brain/ollama_client.dart';

class PlanStep {
  final String action;
  final String target;
  final String? inputParam;
  final String reasoning;

  PlanStep({
    required this.action,
    required this.target,
    this.inputParam,
    required this.reasoning,
  });

  Map<String, dynamic> toJson() => {
    'action': action,
    'target': target,
    'input_param': inputParam,
    'reasoning': reasoning,
  };
}

class SequencePlan {
  final String goal;
  final List<PlanStep> steps;
  final List<String> questions; // [NEW]

  SequencePlan({
    required this.goal, 
    required this.steps, 
    this.questions = const []
  });
}

class PlannerService {
  final OllamaClient ollama;

  PlannerService(this.ollama);

  Future<SequencePlan> generatePlan({
    required String goal,
    required String screenDescription,
  }) async {
    final prompt = '''
    Goal: "$goal"
    Current Screen Context:
    $screenDescription
    
    Task:
    1. Analyze the screen elements relative to the goal.
    2. Identify prerequisites (e.g., must enter text into field X).
    3. Generate a precise sequence of actions.
    4. If data is required (e.g. username), use parameter names (e.g. <username>).
    5. If you are UNSURE about a step or need the user to clarify something (e.g. "Which folder?"), add it to "questions".
    
    Return ONLY a JSON object:
    {
      "reasoning": "Explanation...",
      "questions": ["Question 1?", "Question 2?"],
      "steps": [
        {
          "action": "click" | "type",
          "target": "Exact text",
          "param": "Parameter name or null",
          "why": "Reason"
        }
      ]
    }
    ''';

    final response = await ollama.generate(
      prompt: prompt,
      // format: 'json', 
      numPredict: 512,
    ).timeout(const Duration(seconds: 30));

    try {
      final json = jsonDecode(response);
      final list = json['steps'] as List? ?? [];
      final questions = (json['questions'] as List?)?.map((e) => e.toString()).toList() ?? [];
      
      final steps = list.map((s) => PlanStep(
        action: s['action'] ?? 'unknown',
        target: s['target'] ?? '',
        inputParam: s['param'],
        reasoning: s['why'] ?? '',
      )).toList();

      return SequencePlan(goal: goal, steps: steps, questions: questions);
    } catch (e) {
      throw Exception("Failed to parse plan: $e\nResponse: $response");
    }
  }
}
