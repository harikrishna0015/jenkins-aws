// Healthcare Claims Processing - CI/CD pipeline.
//
// Runs ON the ECS build agent (label 'claims-agent', EC2 launch type). The
// controller is a t3.micro EC2 instance with an Elastic IP; agents connect to
// it directly over JNLP (50000). No tunnel required since both run in AWS.
// See docs/jenkins-setup.md.
//
// AWS credentials are stored in Jenkins as an "AWS Credentials" entry with id
// 'aws-credentials' and injected per-build via withCredentials. No keys in code.

pipeline {
    agent {
        label 'claims-agent'
    }

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION              = 'us-east-1'
        // Artifact bucket created during bootstrap (docs/bootstrap-iam.md).
        // S3 bucket names are globally unique - suffixed with the AWS account id.
        LAMBDA_ARTIFACT_BUCKET  = 'claims-jenkins-artifacts-053849129210'
        ARTIFACT_BUCKET         = "${LAMBDA_ARTIFACT_BUCKET}"
    }

    parameters {
        choice(name: 'TARGET_ENV', choices: ['dev', 'qa', 'prod'], description: 'Which stack to deploy')
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Package Lambda') {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding',
                     credentialsId: 'aws-credentials',
                     accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                     secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']
                ]) {
                    sh '''
                        set -e
                        export AWS_DEFAULT_REGION="${AWS_REGION}"
                        chmod +x scripts/*.sh
                        ./scripts/package.sh
                    '''
                }
            }
        }

        stage('Validate IaC') {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding',
                     credentialsId: 'aws-credentials',
                     accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                     secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']
                ]) {
                    sh '''
                        set -e
                        export AWS_DEFAULT_REGION="${AWS_REGION}"
                        ./scripts/validate.sh
                    '''
                }
            }
        }

        stage("Deploy (${params.TARGET_ENV})") {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding',
                     credentialsId: 'aws-credentials',
                     accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                     secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']
                ]) {
                    sh '''
                        set -e
                        export AWS_DEFAULT_REGION="${AWS_REGION}"
                        ./scripts/deploy.sh ${TARGET_ENV}
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline SUCCESS: ${env.JOB_NAME} #${env.BUILD_NUMBER} deployed to ${params.TARGET_ENV}."
        }
        failure {
            echo "Pipeline FAILED: see stage logs above. Common causes: stale artifact bucket, expired AWS creds, or a CloudFormation drift."
        }
        always {
            // The ECS task is torn down by the ECS plugin when the build ends;
            // the container instance stays registered in the cluster for reuse.
            echo "Agent task terminating."
        }
    }
}
