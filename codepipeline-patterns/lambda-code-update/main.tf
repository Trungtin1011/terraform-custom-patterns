### This pipeline demostrate the following action:
# 1. Lambda function is fetching code from S3 bucket
# 2. Developer commits code changes to AWS CodeCommit
# 3. CodePipeline will trigger CodeBuild
# 4. CodeBuild build the new code and update the Lambda function
# 5. Lambda function is now having the latest code change.

module "aws_pipeline" {
  source = "../../terraform-aws-cicd"

  ### AWS Developer Tools Connection settings
  enable_additional_settings = false
  additional_settings = {
    connection = {
      connection_name = "test-connection"
      connection_type = "GitHub"
    }
    host = {
      host_name     = "example-host"
      host_endpoint = "https://example-host.com"
      host_type     = "GitHub"
      host_vpc_configs = {
        vpc_id             = "vpc-id"
        subnet_ids         = ["ids"]
        security_group_ids = ["ids"]
      }
    }
  }

  ### CodePipeline basic
  create_pipeline = true
  codepipeline_basic = {
    name           = "example-pipeline"
    execution_mode = "QUEUED"
    pipeline_type  = "V2"
  }

  ### CodePipeline service role (Required)
  create_pipeline_role      = true
  pipeline_role_name        = "example-codepipeline-role"
  pipeline_role_description = "AWS CodePipeline service role"
  pipeline_role_policy      = local.codepipeline_policy

  ### CodePipeline artifacts store (Required)
  pipeline_artifacts = [
    {
      location = "${module.artifact_bucket.s3_bucket_id}"
      type     = "S3"
    }
  ]

  ### CodePipelien stages (Required at least TWO stages)
  pipeline_stages = [
    {
      stage_name = "Source"

      action = {
        action_name      = "codeCommitSrc"
        category         = "Source"
        owner            = "AWS"
        provider         = "CodeCommit"
        version          = "1"
        output_artifacts = ["src_output"]
        run_order        = 1
        configuration = {
          RepositoryName       = "${module.aws_repos.code_repo_name}"
          BranchName           = "main"
          PollForSourceChanges = false ### If = false must use EventBridge to trigger pipeline
          OutputArtifactFormat = "CODE_ZIP"
        }
      }
    },
    {
      stage_name = "Build"

      action = {
        action_name     = "lambdaBuild"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        input_artifacts = ["src_output"]
        output_artifact = ["build_output"]
        run_order       = 1
        configuration = {
          ProjectName   = module.aws_builds.codebuild_project_arn
          PrimarySource = "src_output"
          BatchEnabled  = false
        }
      }
    },
  ]

  ### CodePipeline pipeline notification
  codepipeline_notifications = {
    detail_type = "BASIC"
    event_type_ids = [
      "codepipeline-pipeline-action-execution-succeeded",
      "codepipeline-pipeline-action-execution-failed"
    ]
    targets = [
      {
        address = "arn:aws:sns:ap-southeast-1:123456789012:sns-test-topic-1"
        type    = "SNS" # AWS Chatbot (Teams), AWS Chatbot (Slack)
      },
      {
        address = "arn:aws:sns:ap-southeast-1:123456789012:sns-test-topic-2"
        type    = "SNS"
      }
    ]
  }

  tags = {}
}

############################
### Supporting resources ###
############################

### CodeCommit repo
module "aws_repos" {
  source = "/Users/tintrungngo/Documents/lnd/_modules/terraform-aws-cicd//submodules/codecommit"

  ### CodeCommit configurations
  create_codecommit_repo         = true
  codecommit_repo_name           = "example-pipeline-repo"
  codecommit_repo_description    = "CodeCommit Repository"
  codecommit_repo_default_branch = "main"
  enable_repo_approval           = false
  create_repo_trigger            = false
  tags                           = var.tags
}

### CodeBuild project
module "aws_builds" {
  source = "/Users/tintrungngo/Documents/lnd/_modules/terraform-aws-cicd//submodules/codebuild"

  ### CodeBuild project
  create_codebuild_project         = true
  codebuild_project_name           = "example-build-project"
  codebuild_project_description    = "CodeBuild example"
  codebuild_project_public_access  = false
  codebuild_project_visibility     = "PRIVATE"
  codebuild_project_build_timeout  = 60
  codebuild_project_queued_timeout = 480

  ### CodeBuild service role (Required)
  create_codebuild_role      = true
  codebuild_role_name        = "example-codebuild-role"
  codebuild_role_description = "CodeBuild IAM service role"
  codebuild_role_policy      = local.codebuild_policy

  ### CodeBuild source (Required)
  codebuild_source = {
    type      = "NO_SOURCE"
    buildspec = <<EOT
version: 0.2
phases:
  pre_build:
    commands:
      - echo "Pre build, checking current directory..."
      - ls
      - echo "Installing required dependencies..."
      - pip install --upgrade pip
      - pip install -r requirements.txt -t ./package
  build:
    commands:
      - echo Build started on `date`
      - cp -r ./lambda_function/* ./package/
      - cd package
      - zip -r ../lambda_function.zip .
      - aws s3 cp ../lambda_function.zip s3://$BUCKET_NAME/lambda/lambda_function.zip
      - wait
      - aws lambda update-function-code --function-name $LAMBDA_FUNC_NAME --s3-bucket $BUCKET_NAME --s3-key lambda/lambda_function.zip
  post_build:
    commands:
      - echo Build post_build on `date`
      - echo $${LAMBDA_FUNC_NAME}
      - echo $${BUCKET_NAME}
EOT
  }

  ### CodeBuild artifacts (Required)
  codebuild_artifacts = {
    type = "NO_ARTIFACTS"
  }

  ### CodeBuild environment (Required)
  codebuild_environment = {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:5.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false
    environment_variable = [
      {
        name  = "LAMBDA_FUNC_NAME"
        value = "${module.lambda_function.lambda_function_name}"
        type  = "PLAINTEXT" ### PARAMETER_STORE, SECRETS_MANAGER
      },
      {
        name  = "BUCKET_NAME"
        value = "${module.s3_bucket.s3_bucket_id}"
        type  = "PLAINTEXT"
      }
    ]
  }

  tags = var.tags
}


### EventBridge triggers CodePipeline on every commit
module "pipeline_trigger" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "3.0.0"

  ### IAM Role for EventBridge
  create_role        = true
  role_name          = "eventbridge-pipeline-trigger-role"
  role_description   = "EventBridge IAM Role for triggering AWS CodePipeline"
  attach_policy_json = true
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "triggerPipeline"
        Effect   = "Allow"
        Resource = ["*"]
        Action = [
          "codepipeline:StartPipelineExecution"
        ]
      }
    ]
  })

  ### EventBridge Bus Resources Settings
  create_bus = false

  ### EventBridge Rule Resources Settings
  create_rules = true
  rules = {
    pipeline_trigger = {
      "description" = "EventBridge rule for pipeline_trigger"
      "state"       = "ENABLED"
      "event_pattern" = jsonencode(
        { "source" : ["aws.codecommit"],
          "detail-type" : ["CodeCommit Repository State Change"],
          "resources" : ["${module.aws_repos.code_repo_arn}"],
          "detail" : {
            "event" : ["referenceCreated", "referenceUpdated"],
            "referenceType" : ["branch"],
            "referenceName" : ["main"]
          }
        }
      )
    }
  }

  ### EventBridge Target Resources Settings
  create_targets = true
  targets = {
    pipeline_trigger = [
      {
        name            = "AWS CodePipeline"
        arn             = "${module.aws_pipeline.pipeline_arn}"
        attach_role_arn = true
      }
    ]
  }

  ### Tagging
  role_tags = var.tags
  tags = merge(
    var.tags,
    {
      resource_type = "eventbridge"
      resource_name = "eventbridge-pipeline-trigger"
    }
  )
}


### locals.tf file
locals {
  codepipeline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "codeCommitActions"
        Effect   = "Allow"
        Resource = ["arn:aws:codecommit:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
        Action = [
          "codecommit:CancelUploadArchive",
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:GetRepository",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:UploadArchive"
        ]
      },
      {
        Sid      = "readWriteS3"
        Effect   = "Allow"
        Resource = ["arn:aws:s3:::*"]
        Action = [
          "s3:Get*",
          "s3:List*",
          "s3:*Object*"
        ]
      },
      {
        Sid      = "codeBuildAccess"
        Effect   = "Allow"
        Resource = ["arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild",
          "codebuild:BatchGetBuildBatches",
          "codebuild:StartBuildBatch"
        ]
      }
    ]
  })

  codebuild_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "writeLogs"
        Effect   = "Allow"
        Resource = ["*"]
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
      },
      {
        Sid      = "readwriteS3"
        Effect   = "Allow"
        Resource = ["arn:aws:s3:::*"]
        Action = [
          "s3:Get*",
          "s3:List*",
          "s3:*Object*"
        ]
      },
      {
        Sid      = "accessCodeCommit"
        Effect   = "Allow"
        Resource = ["arn:aws:codecommit:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
        Action = [
          "codecommit:GitPull"
        ]
      },
      {
        Sid      = "accessCodeBuild"
        Effect   = "Allow"
        Resource = ["arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
        Action = [
          "codebuild:CreateReportGroup",
          "codebuild:CreateReport",
          "codebuild:UpdateReport",
          "codebuild:BatchPutTestCases",
          "codebuild:BatchPutCodeCoverages"
        ]
      },
      {
        Sid      = "accessLambda"
        Effect   = "Allow"
        Resource = ["arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"]
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:PublishVersion"
        ]
      }
    ]
  })
}
